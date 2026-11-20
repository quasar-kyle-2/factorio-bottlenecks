-- Scans a whole surface and works out, for the buildings the player cares about (the targets),
-- how much of each item their supply chain needs and how much the factory can make of it.
-- See "Demand vs capacity" below.

local api = require("__sw-rates-lib__.api-usage")
local analyzer = require("__sw-rates-lib__.scripts.flow-analyzer")
local lp = require("lp")

local model = {}

model.building_types = {
    "accumulator",
    "agricultural-tower",
    "assembling-machine",
    "asteroid-collector",
    "boiler",
    "burner-generator",
    "electric-energy-interface",
    "furnace",
    "fusion-generator",
    "fusion-reactor",
    "generator",
    "heat-interface",
    "lab",
    "lightning-attractor",
    "mining-drill",
    "offshore-pump",
    "reactor",
    "rocket-silo",
    "simple-entity-with-owner",
    "simple-entity-with-force",
    "solar-panel",
    "thruster",
}

local placer_types = { "inserter", "loader", "loader-1x1" }

local vector_to_place_result_types = {
    ["mining-drill"] = true,
    ["assembling-machine"] = true,
    ["furnace"] = true,
}

--- Node types that never get a balance constraint (treated as unlimited).
local ignored_node_types = {
    ["electric-power"] = true,
    ["electric-buffer"] = true,
    ["pollution"] = true,
    ["science"] = true,
    ["thrust"] = true,
    ["heat"] = true,
    ["item-fuel"] = true,
    ["fluid-fuel"] = true,
    ["fluid-fuel-heat"] = true,
}

local ignored_any_types = {
    ["any-heat"] = true,
    ["any-item-fuel"] = true,
    ["any-fluid-fuel"] = true,
}

--- Waste items, treated as unlimited: what burning a fuel leaves behind, when nothing refills
--- it into that fuel (ash, spent nuclear fuel). There is always more than enough of it, and
--- getting rid of it isn't a real use. Empty canisters, used batteries, used animals and the
--- like are refilled or recharged one for one into their fuel, so they stay counted. Turning
--- 10 ash into 1 coal dust is reprocessing, not refilling: ash is still waste.
local waste_cache = nil ---@type table<string, true>?

---@return table<string, true> item name -> true
local function waste_items()
    if (waste_cache) then
        return waste_cache
    end
    local fuels_of = {} ---@type table<string, table<string, true>> burnt result -> fuels leaving it
    for name, item in pairs(prototypes.item) do
        local burnt = item.burnt_result
        if (burnt) then
            fuels_of[burnt.name] = fuels_of[burnt.name] or {}
            fuels_of[burnt.name][name] = true
        end
    end
    local refilled = {} ---@type table<string, true>
    for _, recipe in pairs(prototypes.recipe) do
        for _, ing in ipairs(recipe.ingredients) do
            local fuels = ing.type == "item" and fuels_of[ing.name]
            if (fuels and not refilled[ing.name]) then
                for _, product in ipairs(recipe.products) do
                    if (product.type == "item" and fuels[product.name]) then
                        local out = product.amount or ((product.amount_min + product.amount_max) / 2)
                        if (out * (product.probability or 1) >= ing.amount) then
                            refilled[ing.name] = true
                            break
                        end
                    end
                end
            end
        end
    end
    waste_cache = {}
    for name, _ in pairs(fuels_of) do
        if (not refilled[name]) then
            waste_cache[name] = true
        end
    end
    return waste_cache
end

--- Fluids treated as unlimited at any temperature.
local ignored_fluids = {
    ["water"] = true,
    -- Unlimited unless the player turns on "Track steam": tracking it was measured at +5.3 s
    -- on a large Py base (2026-11-11).
    ["steam"] = true,
}

--- Fluids that the "Track steam" setting turns back into normal, tracked items.
local steam_fluids = {
    ["steam"] = true,
}

local function fluid_ignored(name, track_steam)
    if (track_steam and steam_fluids[name]) then
        return false
    end
    return ignored_fluids[name] == true
end

--- Amount tags for fuel burnt by a building and its burnt result (e.g. ash).
--- Fuel is treated as unlimited, so these amounts are dropped entirely. (Keeping the burnt
--- results was tried: it adds several seconds on a large Py base and did not give used-up
--- fuel cells a producer anyway.)
local ignored_tags = {
    ["energy-source-input"] = true,
    ["energy-source-output"] = true,
}

---@param node Rates.Node
---@param track_steam boolean?
---@return boolean
local function is_ignored_node(node, track_steam)
    local t = node.type
    if (ignored_node_types[t]) then
        return true
    end
    if (t == "fluid") then
        return fluid_ignored(node.fluid.name, track_steam)
    end
    if (t == "item") then
        return waste_items()[node.item.name] == true
    end
    if (t == "any") then
        local details = node.details
        if (details) then
            if (ignored_any_types[details.type]) then
                return true
            end
            if (details.type == "any-fluid" and details.fluid and fluid_ignored(details.fluid.name, track_steam)) then
                return true
            end
        end
    end
    return false
end

---@param amounts Rates.Configuration.Amount[]
---@return { id: string, node: Rates.Node, amount: number }[]
local function sum_amounts(amounts)
    local by_id, list = {}, {}
    for _, amount in ipairs(amounts) do
        if (ignored_tags[amount.tag]) then
            goto continue
        end
        local id = api.node.get_id(amount.node)
        local entry = by_id[id]
        if (not entry) then
            entry = { id = id, node = amount.node, amount = 0 }
            by_id[id] = entry
            list[#list + 1] = entry
        end
        entry.amount = entry.amount + amount.amount
        ::continue::
    end
    local result = {}
    for _, entry in ipairs(list) do
        if (entry.amount ~= 0) then
            result[#result + 1] = entry
        end
    end
    return result
end

---@class BCE.Row
---@field key string
---@field conf Rates.Configuration
---@field is_target boolean
---@field count_max integer
---@field count_groups table<string, integer>?
---@field entity_ids integer[]
---@field entities LuaEntity[] same order as entity_ids
---@field amounts { id: string, node: Rates.Node, amount: number }[]
---@field annotations Rates.Configuration.Annotation[]?

---@class BCE.Scan
---@field surface_index integer
---@field rows BCE.Row[]
---@field scanned_entities integer
---@field target_entities integer
---@field target_entities_without_conf integer
---@field planned_changes integer ghosts, queued upgrades and pending module requests counted in

--- A recipe that is only for show: hidden, and makes something out of nothing. Pyanodon's dig
--- sites run one (4000 nexelit ore per second) while their digosaurs really walk out and mine
--- the ore by script, at a rate nothing on the building tells. What it "makes" is treated as
--- unlimited, like water: other recipes may make some too, but the dig sites' share can't be
--- told, so counting only those would make it look short.
---@param conf Rates.Configuration
---@return boolean
local function is_fake_recipe(conf)
    local recipe = conf.recipe
    if (not recipe) then
        return false
    end
    local ok, fake = pcall(function()
        return recipe.hidden == true and #recipe.ingredients == 0
    end)
    return ok and fake == true
end

---@param surface LuaSurface
---@param force LuaForce
---@param target_ids table<integer, true>
---@param use_analyzer boolean
---@return BCE.Scan
function model.scan(surface, force, target_ids, use_analyzer)
    -- Planned changes count as done (like sw-rates-calc-extreme): ghosts are included,
    -- buildings marked for upgrade use their upgrade target, pending module requests are
    -- applied and buildings marked for deconstruction are left out.
    local entities = surface.find_entities_filtered { type = model.building_types, force = force }
    for _, ghost in ipairs(surface.find_entities_filtered { ghost_type = model.building_types, force = force }) do
        entities[#entities + 1] = ghost
    end
    local list = {} ---@type LuaEntity[]
    local planned = 0
    local ctx = use_analyzer and analyzer.create_context() or nil
    for _, entity in ipairs(entities) do
        if (entity.valid and entity.unit_number and not entity.to_be_deconstructed()) then
            list[#list + 1] = entity
            local is_ghost = entity.type == "entity-ghost"
            if (is_ghost or entity.get_upgrade_target() or entity.item_request_proxy) then
                planned = planned + 1
            end
            if (ctx) then
                analyzer.add_required_entity(ctx, entity)
                if (vector_to_place_result_types[is_ghost and entity.ghost_type or entity.type]) then
                    analyzer.add_item_placer(ctx, entity)
                end
            end
        end
    end

    if (ctx) then
        local placers = surface.find_entities_filtered { type = placer_types, force = force }
        for _, ghost in ipairs(surface.find_entities_filtered { ghost_type = placer_types, force = force }) do
            placers[#placers + 1] = ghost
        end
        for _, entity in ipairs(placers) do
            if (entity.valid and entity.unit_number and not entity.to_be_deconstructed()) then
                analyzer.add_item_placer(ctx, entity)
            end
        end
        analyzer.analyze_full(ctx)
    end

    local use_pollution = game.map_settings.pollution.enabled
    local rows_by_key = {} ---@type table<string, BCE.Row>
    local rows = {} ---@type BCE.Row[]
    local fake_items = {} ---@type table<string, true> made by a show-only recipe

    ---@return BCE.Row
    local function get_row(key, conf, is_target)
        local row = rows_by_key[key]
        if (not row) then
            local annotations = api.configuration.get_annotations(conf)
            local amounts = api.configuration.get_production(conf, {
                force = force,
                surface = surface,
                use_pollution = use_pollution,
                annotations = annotations,
            })
            local summed = sum_amounts(amounts or {})
            if (not is_target and is_fake_recipe(conf)) then
                local kept_amounts = {}
                for _, a in ipairs(summed) do
                    if (a.amount < 0) then
                        kept_amounts[#kept_amounts + 1] = a
                    else
                        fake_items[a.id] = true
                    end
                end
                summed = kept_amounts
            end
            row = {
                key = key,
                conf = conf,
                is_target = is_target,
                count_max = 0,
                entity_ids = {},
                entities = {},
                amounts = summed,
                annotations = annotations,
            }
            rows_by_key[key] = row
            rows[#rows + 1] = row
        end
        return row
    end

    local target_entities, target_without_conf = 0, 0
    for _, entity in ipairs(list) do
        local is_target = target_ids[entity.unit_number] == true
        if (is_target) then
            target_entities = target_entities + 1
        end
        local inputs = ctx and analyzer.get_entity_inputs(ctx, entity) or nil
        local conf = api.configuration.get_from_entity(entity, { use_ghosts = true, analyzer_inputs = inputs })
        if (conf) then
            if (conf.type == "meta" and #conf.children > 1 and not is_target) then
                local meta_id = api.configuration.get_id(conf)
                for _, child in ipairs(conf.children) do
                    local row = get_row(api.configuration.get_id(child), child, false)
                    row.count_groups = row.count_groups or {}
                    row.count_groups[meta_id] = (row.count_groups[meta_id] or 0) + 1
                    row.entity_ids[#row.entity_ids + 1] = entity.unit_number
                    row.entities[#row.entities + 1] = entity
                end
            else
                local key = api.configuration.get_id(conf)
                if (is_target) then
                    key = "target|" .. key
                end
                local row = get_row(key, conf, is_target)
                row.count_max = row.count_max + 1
                row.entity_ids[#row.entity_ids + 1] = entity.unit_number
                row.entities[#row.entities + 1] = entity
            end
        elseif (is_target) then
            target_without_conf = target_without_conf + 1
        end
    end

    ---@type BCE.Scan
    return {
        surface_index = surface.index,
        rows = rows,
        scanned_entities = #list,
        target_entities = target_entities,
        target_entities_without_conf = target_without_conf,
        planned_changes = planned,
        fake_items = fake_items,
    }
end

---@param row BCE.Row
---@return integer
local function total_count(row)
    local count = row.count_max
    for _, c in pairs(row.count_groups or {}) do
        count = count + c
    end
    return count
end

--- Builds node statistics over all rows.
---@param rows BCE.Row[]
local function collect_nodes(rows)
    local nodes = {} ---@type table<string, { node: Rates.Node, producers: integer[], consumers: integer[], has_positive: boolean?, children: string[]? }>
    for ri, row in ipairs(rows) do
        for _, a in ipairs(row.amounts) do
            local e = nodes[a.id]
            if (not e) then
                e = { node = a.node, producers = {}, consumers = {} }
                nodes[a.id] = e
            end
            if (a.amount > 0) then
                e.producers[#e.producers + 1] = ri
                e.has_positive = true
            else
                e.consumers[#e.consumers + 1] = ri
            end
        end
    end

    for _, e in pairs(nodes) do
        if (e.node.type == "any") then
            e.children = {}
            for _, child in ipairs(e.node.children) do
                local cid = api.node.get_id(child)
                local ce = nodes[cid]
                if (ce and ce.has_positive) then
                    e.children[#e.children + 1] = cid
                    e.any_produced = true
                end
            end
        end
    end
    for _, e in pairs(nodes) do
        if (e.any_produced) then
            e.has_positive = true
        end
    end
    return nodes
end

---@param e { node: Rates.Node, has_positive: boolean? }
---@return "ignored" | "free" | "counted"
local function default_mode(id, e, track_steam, fake_items)
    if (is_ignored_node(e.node, track_steam) or (fake_items and fake_items[id])) then
        return "ignored"
    end
    if (not e.has_positive) then
        return "free"
    end
    return "counted"
end

--- Rows upstream of the targets, through counted items (and "any" nodes' children).
---@param rows BCE.Row[]
---@param nodes table
---@param modes table<string, string>
---@return table<integer, true>
local function upstream_of_targets(rows, nodes, modes)
    local keep = {} ---@type table<integer, true>
    local queue = {} ---@type integer[]
    local function push(ri)
        if (not keep[ri]) then
            keep[ri] = true
            queue[#queue + 1] = ri
        end
    end
    local function push_producers(id)
        for _, ri in ipairs(nodes[id].producers) do
            push(ri)
        end
    end
    for ri, row in ipairs(rows) do
        if (row.is_target) then
            push(ri)
        end
    end
    local head = 1
    while (head <= #queue) do
        local row = rows[queue[head]]
        head = head + 1
        for _, a in ipairs(row.amounts) do
            local id = a.id
            if (a.amount < 0 and modes[id] == "counted") then
                push_producers(id)
                for _, cid in ipairs(nodes[id].children or {}) do
                    if (modes[cid] == "counted") then
                        push_producers(cid)
                    end
                end
            end
        end
    end
    return keep
end

-- ---------------------------------------------------------------------------
-- Demand vs capacity
--
-- How much of each item the targets' supply chain needs when every target group runs at the
-- speed the player chose, and how much the factory can make of it. Every building upstream of
-- the targets may run as much as that takes, however many there are, so a shortage anywhere
-- never hides what is needed further upstream; nothing that doesn't feed the targets adds any
-- need. The solver works out which recipes make what: in loops, with byproducts and with
-- several recipes for one item there is no single obvious answer, so it uses the buildings you
-- already have first, and only goes past them where it has to, as little as possible.
--
--   variables: x_r = buildings running row r (targets: up to speed × count). Other rows have
--              two columns with the same coefficients: up to the buildings you have (cheap),
--              and any amount beyond that (expensive)
--   items:     net production >= 0 (counted items); unlimited and unmade items have no row
--   objective: run the targets at their speed first; then keep the extra buildings cheap,
--              each priced by what it takes to fit in (building_cost), however many of it
--              you have; then use as few of your own buildings as possible, each counted
--              relative to how many you have of it
--
-- Per item: needed = what the chain uses at those rates; can make = what the buildings it uses
-- to make the item would make at 100% with the buildings you have. Coverage = can make ÷
-- needed: below 100% the item is short at the chosen speeds, and it runs out once the targets
-- are turned up past that fraction of them.

local EPS = 1e-7
local W_TARGET = 1e4
--- per unit of building_cost, for each building beyond the ones you have
local W_OVER = 1e-2
--- per building you have, relative to how many you have
local W_BUILDINGS = 1e-3
--- Buildings running less than this are solver noise.
local RUN_TOL = 1e-6
--- Items needed or made slower than this per second are solver noise.
local NEED_TOL = 1e-4

--- What one more building of a row takes to fit in: its width in tiles, a belt, pipe or
--- inserter for each item and fluid it uses or makes, a heat pipe if it runs on heat, and fuel
--- (plus its burnt result) if it burns something. Whatever you already have of it.
---@param row BCE.Row
---@return number
local function building_cost(row)
    local proto = row.conf and row.conf.entity
    local cost = 0
    local ok = proto and pcall(function()
        cost = proto.tile_width or 3
        if (proto.heat_energy_source_prototype) then
            cost = cost + 1
        end
        if (proto.burner_prototype) then
            cost = cost + 2
        elseif (proto.fluid_energy_source_prototype) then
            cost = cost + 1
        end
    end)
    if (not ok) then
        cost = 3
    end
    for _, a in ipairs(row.amounts) do
        local t = a.node.type
        if (t == "item" or t == "fluid" or t == "any") then
            cost = cost + 1
        end
    end
    return cost
end

---@param scan BCE.Scan
---@param overrides table<string, string> node id -> "ignored" (treated as unlimited)
---@param track_steam boolean?
---@param speeds table<string, number> target row key -> speed (1 = 100%); missing = 100%
function model.build(scan, overrides, track_steam, speeds)
    local rows = scan.rows
    local nodes = collect_nodes(rows)

    local modes, defaults = {}, {} ---@type table<string, string>, table<string, string>
    for id, e in pairs(nodes) do
        local d = default_mode(id, e, track_steam, scan.fake_items)
        defaults[id] = d
        modes[id] = (d == "counted" and overrides[id] == "ignored") and "ignored" or d
    end
    local function counted(id)
        return modes[id] == "counted"
    end

    local keep = upstream_of_targets(rows, nodes, modes)
    local kept = {} ---@type integer[]
    for ri = 1, #rows do
        if (keep[ri]) then
            kept[#kept + 1] = ri
        end
    end

    local n, m = 0, 0
    local cols, upper, cost = {}, {}, {}
    local b, sign = {}, {}
    local function var(ub)
        n = n + 1
        cols[n] = {}
        upper[n] = ub
        return n
    end
    local function set(i, j, a)
        local v = (cols[j][i] or 0) + sign[i] * a
        cols[j][i] = (v ~= 0) and v or nil
    end

    -- buildings of a machine that switches between recipes count evenly toward each of them
    local meta_children = {} ---@type table<string, integer>
    for _, ri in ipairs(kept) do
        for meta_id, _ in pairs(rows[ri].count_groups or {}) do
            meta_children[meta_id] = (meta_children[meta_id] or 0) + 1
        end
    end

    local row_var = {} ---@type table<integer, integer>
    -- Each target group also has an unrewarded twin column: lowering its speed hands the excess
    -- to the twin without changing anything else, so the solver can continue from there.
    -- For other rows the twin is the expensive column: buildings beyond the ones you have.
    local twin_var = {} ---@type table<integer, integer>
    local n_targets = 0
    for _, ri in ipairs(kept) do
        local row = rows[ri]
        local count = math.max(1, total_count(row))
        if (row.is_target) then
            n_targets = n_targets + 1
            local v = var((speeds[row.key] or 1) * row.count_max)
            cost[v] = -W_TARGET / count
            row_var[ri] = v
            twin_var[ri] = var(nil)
        else
            local have = row.count_max
            for meta_id, k in pairs(row.count_groups or {}) do
                have = have + k / meta_children[meta_id]
            end
            if (have > 0) then
                local v = var(have)
                cost[v] = W_BUILDINGS / count
                row_var[ri] = v
                local o = var(nil)
                cost[o] = W_OVER * building_cost(row)
                twin_var[ri] = o
            else
                local v = var(nil)
                cost[v] = W_OVER * building_cost(row)
                row_var[ri] = v
            end
        end
    end

    -- item balances: net production >= 0. Every row gets a tiny distinct offset: many balances
    -- are exactly 0, and that many tied rows make the simplex stall.
    local need = {} ---@type table<string, true>
    for _, ri in ipairs(kept) do
        for _, a in ipairs(rows[ri].amounts) do
            if (counted(a.id) and a.amount < 0) then
                need[a.id] = true
                for _, cid in ipairs(nodes[a.id].children or {}) do
                    if (counted(cid)) then
                        need[cid] = true
                    end
                end
            end
        end
    end
    local need_sorted = {} ---@type string[]
    for id, _ in pairs(need) do
        need_sorted[#need_sorted + 1] = id
    end
    table.sort(need_sorted)
    local node_con = {} ---@type table<string, integer>
    for _, id in ipairs(need_sorted) do
        m = m + 1
        b[m] = EPS * (1 + ((m * 7919) % 1000) / 1000)
        sign[m] = -1
        node_con[id] = m
    end
    for _, ri in ipairs(kept) do
        local v, t = row_var[ri], twin_var[ri]
        for _, a in ipairs(rows[ri].amounts) do
            local i = node_con[a.id]
            if (i) then
                set(i, v, a.amount)
                if (t) then
                    set(i, t, a.amount)
                end
            end
        end
    end
    -- "any" nodes (a fluid at any temperature) are made by their children's producers
    local transfers = {} ---@type { any: string, child: string, var: integer }[]
    for _, id in ipairs(need_sorted) do
        for _, cid in ipairs(nodes[id].children or {}) do
            if (node_con[cid]) then
                local t = var(nil)
                set(node_con[id], t, 1)
                set(node_con[cid], t, -1)
                transfers[#transfers + 1] = { any = id, child = cid, var = t }
            end
        end
    end

    local state = lp.create({
        n = n,
        m = m,
        cols = cols,
        upper = upper,
        b = b,
        slack_upper = {},
        costs = { cost },
        weights = { 1 },
    })
    return {
        lp = state,
        kept = kept,
        row_var = row_var,
        twin_var = twin_var,
        node_con = node_con,
        transfers = transfers,
        modes = modes,
        defaults = defaults,
        nodes = nodes,
        n_targets = n_targets,
        n_constraints = m,
        track_steam = track_steam or false,
    }
end

--- Change a target group's speed on a solved model, so lp.step continues from the last answer
--- instead of solving again from scratch. False when that isn't possible (build it again).
---@param built table
---@param scan BCE.Scan
---@param row_key string
---@param speed number
---@return boolean
function model.set_speed(built, scan, row_key, speed)
    for _, ri in ipairs(built.kept) do
        local row = scan.rows[ri]
        if (row.key == row_key and row.is_target) then
            return lp.lower_into(built.lp, built.row_var[ri], speed * row.count_max, built.twin_var[ri])
        end
    end
    return false
end

---@class BCE.Item
---@field id string
---@field node Rates.Node
---@field mode "counted" | "free" | "ignored"
---@field default_mode string
---@field needed number per second, used by the target chain at the chosen speeds
---@field made number per second, made at those rates (needed plus what comes along anyway)
---@field capacity number per second, what the buildings used to make it make at 100%
---@field coverage number? capacity / needed

---@class BCE.Result
---@field status string
---@field items BCE.Item[]
---@field targets { row: BCE.Row, speed: number, reached: number }[]
---@field chain_units table<integer, true>
---@field chain_buildings integer
---@field target_entities integer
---@field target_entities_without_conf integer
---@field scanned_entities integer
---@field planned_changes integer
---@field track_steam boolean
---@field row_x table<integer, number> scan row index -> buildings the plan runs (rows feeding the targets)
---@field row_have table<integer, number> scan row index -> buildings you have of it
---@field main_of table<integer, string> scan row index -> its main product

--- Reads the solved model.
---@param built table
---@param scan BCE.Scan
---@param speeds table<string, number>
---@return BCE.Result
function model.results(built, scan, speeds)
    local st = built.lp
    local rows = scan.rows
    local modes, nodes = built.modes, built.nodes

    local items = {} ---@type table<string, BCE.Item>
    local function item(id)
        local e = items[id]
        if (not e) then
            e = { id = id, node = nodes[id].node, mode = modes[id], default_mode = built.defaults[id],
                needed = 0, made = 0, capacity = 0 }
            items[id] = e
        end
        return e
    end

    -- buildings of a machine that switches between recipes count evenly toward each of them
    local meta_children = {} ---@type table<string, integer>
    for _, ri in ipairs(built.kept) do
        for meta_id, _ in pairs(rows[ri].count_groups or {}) do
            meta_children[meta_id] = (meta_children[meta_id] or 0) + 1
        end
    end
    local function count_of(row)
        local c = row.count_max
        for meta_id, k in pairs(row.count_groups or {}) do
            c = c + k / meta_children[meta_id]
        end
        return c
    end

    --- What a building is there for: its recipe's main product, or its only tracked product.
    local function main_product(row)
        local conf = row.conf
        if (conf and conf.type == "meta" and conf.children) then
            conf = conf.children[1]
        end
        local recipe = conf and conf.recipe
        local mp = recipe and recipe.main_product
        local only, n = nil, 0
        for _, a in ipairs(row.amounts) do
            if (a.amount > 0 and modes[a.id] == "counted") then
                local node = nodes[a.id].node
                if (mp and ((node.type == "item" and node.item.name == mp.name)
                        or (node.type == "fluid" and node.fluid.name == mp.name))) then
                    return a.id
                end
                only, n = a.id, n + 1
            end
        end
        return n == 1 and only or nil
    end

    local targets = {}
    local chain_units, chain_buildings = {}, 0
    local row_x, row_have, main_of = {}, {}, {} ---@type table<integer, number>, table<integer, number>, table<integer, string>
    for _, ri in ipairs(built.kept) do
        local row = rows[ri]
        local x = lp.value(st, built.row_var[ri])
        if (built.twin_var[ri]) then
            x = x + lp.value(st, built.twin_var[ri])
        end
        if (x < RUN_TOL) then
            x = 0
        end
        row_x[ri] = x
        if (row.is_target) then
            local speed = speeds[row.key] or 1
            local goal = speed * row.count_max
            targets[#targets + 1] = { row = row, speed = speed, reached = goal > 0 and math.min(1, x / goal) or 1 }
        end
        if (x > 0 or row.is_target) then
            for _, unit_number in ipairs(row.entity_ids) do
                if (not chain_units[unit_number]) then
                    chain_units[unit_number] = true
                    chain_buildings = chain_buildings + 1
                end
            end
        end
        -- Can make: every building whose main product it is, whether or not the solver needed
        -- it (two setups of the same recipe are equally good, and it only needs one of them),
        -- plus any other building the solver runs that makes it along the way.
        local main = (not row.is_target) and main_product(row) or nil
        local count = count_of(row)
        row_have[ri] = count
        main_of[ri] = main
        for _, a in ipairs(row.amounts) do
            if (modes[a.id] ~= nil and nodes[a.id].node.type ~= "map-entity") then
                if (a.amount < 0) then
                    if (x > 0) then
                        item(a.id).needed = item(a.id).needed - a.amount * x
                    end
                elseif (not row.is_target and (x > 0 or a.id == main)) then
                    local e = item(a.id)
                    e.made = e.made + a.amount * x
                    e.capacity = e.capacity + a.amount * count
                end
            end
        end
    end
    -- what goes into an "any" node counts for the child that supplies it
    for _, tr in ipairs(built.transfers) do
        local x = lp.value(st, tr.var)
        if (x > RUN_TOL) then
            item(tr.child).needed = item(tr.child).needed + x
        end
    end

    local list = {} ---@type BCE.Item[]
    for id, e in pairs(items) do
        local children = nodes[id].children
        -- "any" nodes are shown through their children, unless nothing makes them
        if (not (children and #children > 0 and e.mode == "counted")) then
            -- the solver's tiny balance offsets leave crumbs behind
            if (e.needed < NEED_TOL) then
                e.needed = 0
            end
            if (e.made < NEED_TOL) then
                e.made = 0
            end
            if (e.needed > 0) then
                e.coverage = e.capacity / e.needed
            end
            if (e.needed > 0 or e.made > 0) then
                list[#list + 1] = e
            end
        end
    end
    table.sort(list, function(a, c) return a.id < c.id end)

    return {
        status = st.status,
        items = list,
        targets = targets,
        chain_units = chain_units,
        chain_buildings = chain_buildings,
        target_entities = scan.target_entities,
        target_entities_without_conf = scan.target_entities_without_conf,
        scanned_entities = scan.scanned_entities,
        planned_changes = scan.planned_changes or 0,
        track_steam = built.track_steam,
        row_x = row_x,
        row_have = row_have,
        main_of = main_of,
    }
end

return model
