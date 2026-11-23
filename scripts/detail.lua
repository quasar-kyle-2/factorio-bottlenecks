-- Item report: where an item goes and where it comes from, from the last answer and from what
-- the buildings are doing right now.

local api = require("__sw-rates-lib__.api-usage")

local detail = {}

---@class BCE.DetailRow
---@field ri integer scan row index
---@field row BCE.Row
---@field per_building number item per second per building at 100%
---@field have number buildings you have
---@field x number? buildings the plan runs (nil: doesn't feed the targets)
---@field rate number? item per second the plan uses or makes here
---@field byproducts string[]? other things it makes (node ids)
---@field short_inputs string[]? its ingredients that are short (node ids)
---@field other_inputs string[]? its other ingredients (node ids)
---@field products string[]? consumers: what it makes, lowest coverage first (node ids)
---@field live BCE.Live?

---@class BCE.Live
---@field total integer
---@field working integer
---@field waiting_this integer waiting for this item
---@field stalled integer waiting for another ingredient
---@field waiting { id: string?, node: Rates.Node?, icon: string, n: integer }[] those ingredients, most buildings first
---@field output_full integer
---@field other integer

---@param node Rates.Node
---@return string? "item" | "fluid"
---@return string? name
local function node_name(node)
    if (node.type == "item") then
        return "item", node.item.name
    elseif (node.type == "fluid") then
        return "fluid", node.fluid.name
    end
    return nil, nil
end

--- Whether a node is this item or fluid. A fluid matches at any temperature, and so does a fluid
--- ingredient's temperature range ("any" node).
---@param node Rates.Node
---@param type string "item" | "fluid"
---@param name string
---@return boolean
function detail.node_is(node, type, name)
    if (node.type == "item") then
        return type == "item" and node.item.name == name
    elseif (node.type == "fluid") then
        return type == "fluid" and node.fluid.name == name
    elseif (node.type == "any") then
        local d = node.details
        return type == "fluid" and d ~= nil and d.type == "any-fluid" and d.fluid ~= nil and d.fluid.name == name
    end
    return false
end

--- The report id for an item or fluid picked by name: the item in that quality first (any
--- quality otherwise), a fluid itself before a temperature range. nil: nothing on the surface
--- makes or uses it.
---@param scan BCE.Scan
---@param result BCE.Result
---@param type string "item" | "fluid"
---@param name string
---@param quality string?
---@return string?
function detail.find_id(scan, result, type, name, quality)
    quality = quality or "normal"
    local best, best_score
    local function consider(id, node)
        if (not detail.node_is(node, type, name)) then
            return
        end
        local score = 0
        if ((node.type == "item" and node.quality.name == quality) or node.type == "fluid") then
            score = 1
        end
        if (not best or score > best_score) then
            best, best_score = id, score
        end
    end
    for _, e in ipairs(result.items) do
        consider(e.id, e.node)
    end
    if (best) then
        return best
    end
    for _, row in ipairs(scan.rows) do
        for _, a in ipairs(row.amounts) do
            consider(a.id, a.node)
        end
    end
    return best
end

local status_name = {} ---@type table<integer, string>
for name, value in pairs(defines.entity_status) do
    status_name[value] = name
end

local input_inventories = {
    defines.inventory.crafter_input or defines.inventory.assembling_machine_input,
    defines.inventory.lab_input,
}

--- What a building has of an ingredient, ready to use.
---@param entity LuaEntity
---@param type string
---@param name string
local function stock(entity, type, name)
    if (type == "fluid") then
        return entity.get_fluid_count(name)
    end
    for _, index in ipairs(input_inventories) do
        local inv = index and entity.get_inventory(index)
        if (inv) then
            return inv.get_item_count(name)
        end
    end
    return entity.get_item_count(name)
end

--- What the buildings of a row are doing now, and which ingredient they wait for.
---@param row BCE.Row
---@param this_type string?
---@param this_name string?
---@return BCE.Live
local function read_live(row, this_type, this_name)
    local live = { total = 0, working = 0, waiting_this = 0, stalled = 0, waiting = {}, output_full = 0, other = 0 }
    local waiting = {} ---@type table<string, { id: string?, node: Rates.Node?, icon: string, n: integer }>
    local ingredients = {}
    local conf = row.conf
    if (conf and conf.type == "meta" and conf.children) then
        conf = conf.children[1]
    end
    local recipe = conf and conf.recipe
    if (recipe) then
        pcall(function()
            for _, ing in ipairs(recipe.ingredients) do
                local i = { type = ing.type, name = ing.name, amount = ing.amount,
                    icon = "[" .. ing.type .. "=" .. ing.name .. "]" }
                -- its node in the row, for a button that opens its report
                for _, a in ipairs(row.amounts) do
                    if (a.amount < 0 and detail.node_is(a.node, ing.type, ing.name)) then
                        i.id, i.node = a.id, a.node
                        break
                    end
                end
                ingredients[#ingredients + 1] = i
            end
        end)
    end
    for _, entity in ipairs(row.entities or {}) do
        if (entity.valid) then
            live.total = live.total + 1
            local ok, status = pcall(function() return entity.status end)
            local sname = ok and status and status_name[status] or ""
            if (sname == "working" or sname == "low_power") then
                live.working = live.working + 1
            elseif (sname == "full_output" or sname == "output_full" or sname == "full_burnt_result_output") then
                live.output_full = live.output_full + 1
            else
                -- the first ingredient it has less than one craft of
                local missing = nil
                for _, ing in ipairs(ingredients) do
                    local okc, have = pcall(stock, entity, ing.type, ing.name)
                    if (okc and have < ing.amount) then
                        if (ing.type == this_type and ing.name == this_name) then
                            missing = true
                            break
                        end
                        missing = missing or ing
                    end
                end
                if (missing == true) then
                    live.waiting_this = live.waiting_this + 1
                elseif (missing) then
                    live.stalled = live.stalled + 1
                    local w = waiting[missing.icon]
                    if (not w) then
                        w = { id = missing.id, node = missing.node, icon = missing.icon, n = 0 }
                        waiting[missing.icon] = w
                        live.waiting[#live.waiting + 1] = w
                    end
                    w.n = w.n + 1
                else
                    live.other = live.other + 1
                end
            end
        end
    end
    table.sort(live.waiting, function(a, b) if (a.n ~= b.n) then return a.n > b.n end return a.icon < b.icon end)
    return live
end

---@class BCE.Detail
---@field id string
---@field item BCE.Item?
---@field node Rates.Node
---@field consumers BCE.DetailRow[]
---@field producers BCE.DetailRow[]
---@field path { id: string?, row: BCE.Row? }[] main route on to the targets

--- Everything the report shows about an item.
---@param scan BCE.Scan
---@param result BCE.Result
---@param id string
---@return BCE.Detail?
function detail.build(scan, result, id)
    local items = {} ---@type table<string, BCE.Item>
    for _, e in ipairs(result.items) do
        items[e.id] = e
    end
    local node
    local consumers, producers = {}, {}
    for ri, row in ipairs(scan.rows) do
        for _, a in ipairs(row.amounts) do
            if (a.id == id) then
                node = node or a.node
                local x = result.row_x and result.row_x[ri]
                local have = result.row_have and result.row_have[ri] or row.count_max
                local d = { ri = ri, row = row, per_building = math.abs(a.amount), have = have, x = x,
                    rate = x and math.abs(a.amount) * x or nil }
                if (a.amount < 0) then
                    -- what it makes, the shortest first: that's usually why it wants this item
                    d.products = {}
                    for _, b in ipairs(row.amounts) do
                        local e = items[b.id]
                        if (b.amount > 0 and e and e.mode == "counted") then
                            d.products[#d.products + 1] = b.id
                        end
                    end
                    table.sort(d.products, function(p, q)
                        local cp, cq = items[p].coverage or math.huge, items[q].coverage or math.huge
                        if (cp ~= cq) then return cp < cq end
                        return p < q
                    end)
                    consumers[#consumers + 1] = d
                elseif (not row.is_target) then
                    d.byproducts, d.short_inputs, d.other_inputs = {}, {}, {}
                    for _, b in ipairs(row.amounts) do
                        local e = items[b.id]
                        if (b.id ~= id and e) then
                            if (b.amount > 0) then
                                if (e.mode == "counted") then
                                    d.byproducts[#d.byproducts + 1] = b.id
                                end
                            elseif (e.mode == "counted" and e.coverage and e.coverage < 1) then
                                d.short_inputs[#d.short_inputs + 1] = b.id
                            elseif (b.amount < 0) then
                                d.other_inputs[#d.other_inputs + 1] = b.id
                            end
                        end
                    end
                    producers[#producers + 1] = d
                end
            end
        end
    end
    if (not node) then
        return nil
    end
    local this_type, this_name = node_name(node)
    for _, d in ipairs(consumers) do
        d.live = read_live(d.row, this_type, this_name)
    end
    for _, d in ipairs(producers) do
        d.live = read_live(d.row, nil, nil)
    end
    -- targets' chain first, biggest first
    local function order(a, b)
        if ((a.x ~= nil) ~= (b.x ~= nil)) then return a.x ~= nil end
        local ra, rb = a.rate or 0, b.rate or 0
        if (ra ~= rb) then return ra > rb end
        local ca, cb = a.per_building * a.have, b.per_building * b.have
        if (ca ~= cb) then return ca > cb end
        return a.ri < b.ri
    end
    table.sort(consumers, order)
    table.sort(producers, order)

    -- on to the targets: follow the biggest use, then what that building is there to make
    local path = {}
    local seen = { [id] = true }
    local cur = id
    for _ = 1, 15 do
        local best, best_rate = nil, 0
        for ri, row in ipairs(scan.rows) do
            local x = result.row_x and result.row_x[ri]
            if (x and x > 0) then
                for _, a in ipairs(row.amounts) do
                    if (a.id == cur and a.amount < 0 and -a.amount * x > best_rate) then
                        best, best_rate = ri, -a.amount * x
                    end
                end
            end
        end
        if (not best) then
            break
        end
        local row = scan.rows[best]
        if (row.is_target) then
            path[#path + 1] = { row = row }
            break
        end
        -- a short product is what the plan is pushing this building for, so follow that;
        -- otherwise what the building is there to make
        local nxt, lowest = nil, 1
        for _, a in ipairs(row.amounts) do
            local e = items[a.id]
            if (a.amount > 0 and e and e.mode == "counted" and not seen[a.id]
                    and e.coverage and e.coverage < lowest) then
                nxt, lowest = a.id, e.coverage
            end
        end
        nxt = nxt or (result.main_of and result.main_of[best])
        if (not nxt) then
            -- no main product: the biggest counted thing it makes
            local most = 0
            for _, a in ipairs(row.amounts) do
                local e = items[a.id]
                if (a.amount > most and e and e.mode == "counted") then
                    nxt, most = a.id, a.amount
                end
            end
        end
        if (not nxt or seen[nxt]) then
            break
        end
        seen[nxt] = true
        path[#path + 1] = { id = nxt }
        cur = nxt
    end

    return { id = id, item = items[id], node = node, consumers = consumers, producers = producers, path = path }
end

-- ---------------------------------------------------------------------------
-- Productivity: where productivity modules cut the demand for an item the most
--
-- Every building group the plan runs pulls on the item, directly or through its ingredients:
-- its "draw" is the item per second its inputs cost, all the way up the chain. With its output
-- held where it is, a group with productivity p uses 1/(1+p) of the inputs it uses without
-- any, so its draw scales the same way. Only productivity matters: speed, beacons and building
-- counts only change how many buildings it takes to keep the output.
--
-- Each group is scored as if its own modules were taken out (beacons and everything else
-- stay): what filling every slot with the best productivity module that fits and is unlocked
-- saves, per module. Full groups keep their place in the list, so it shows at a glance whether
-- the modules you have are in the best spots.

local cutil = require("__sw-rates-lib__.scripts.configuration-util")

--- Every productivity module and the recipes that make it. Prototype data, the same for every
--- player and save, so it is worked out once.
local prod_module_recipes = nil ---@type { module: LuaItemPrototype, recipes: string[] }[]?

--- The productivity modules the force can make: an enabled recipe makes them.
---@param force LuaForce
---@return LuaItemPrototype[]
local function unlocked_prod_modules(force)
    if (not prod_module_recipes) then
        prod_module_recipes = {}
        for name, m in pairs(prototypes.get_item_filtered({ { filter = "type", type = "module" } })) do
            local fx = m.module_effects
            if (fx and (fx.productivity or 0) > 0) then
                local recipes = {}
                for rname, _ in pairs(prototypes.get_recipe_filtered({ { filter = "has-product-item",
                        elem_filters = { { filter = "name", name = name } } } })) do
                    recipes[#recipes + 1] = rname
                end
                prod_module_recipes[#prod_module_recipes + 1] = { module = m, recipes = recipes }
            end
        end
        table.sort(prod_module_recipes, function(x, y) return x.module.name < y.module.name end)
    end
    local list = {}
    for _, e in ipairs(prod_module_recipes) do
        for _, rname in ipairs(e.recipes) do
            local r = force.recipes[rname]
            if (r and r.enabled) then
                list[#list + 1] = e.module
                break
            end
        end
    end
    return list
end

local good_when_positive = { speed = true, productivity = true, quality = true }

--- Whether a module goes in: every effect it gives is allowed, and its category is.
---@param m LuaItemPrototype
---@param allowed table<string, boolean>?
---@param categories table<string, boolean>?
local function module_allowed(m, allowed, categories)
    if (categories and not categories[m.category]) then
        return false
    end
    if (allowed) then
        for name, value in pairs(m.module_effects or {}) do
            local good = good_when_positive[name] and value > 0 or (not good_when_positive[name] and value < 0)
            if (good and not allowed[name]) then
                return false
            end
        end
    end
    return true
end

---@class BCE.ProdInfo
---@field slots integer module slots per building
---@field module LuaItemPrototype the best productivity module that fits
---@field p_none number productivity without its modules
---@field p_now number
---@field p_max number every slot holding that module

--- What productivity a group gets without its modules, now, and with every slot holding the
--- best productivity module that fits and is unlocked. nil: no such module, or it adds nothing.
---@param conf Rates.Configuration
---@param force LuaForce
---@param surface LuaSurface?
---@param modules LuaItemPrototype[] unlocked productivity modules
---@return BCE.ProdInfo?
local function prod_info(conf, force, surface, modules)
    if (conf.type == "meta" and conf.children) then
        conf = conf.children[1]
    end
    local entity = conf.entity
    local additional, max_effect = {}, nil
    if (conf.type == "crafting-machine") then
        local r = force.recipes[conf.recipe.name]
        additional[1] = { productivity = r and r.productivity_bonus or 0 }
        max_effect = { productivity = conf.recipe.maximum_productivity }
    elseif (conf.type == "mining-drill") then
        if (entity.uses_force_mining_productivity_bonus) then
            additional[1] = { productivity = force.mining_drill_productivity_bonus }
        end
    elseif (conf.type == "lab") then
        additional[1] = { productivity = force.laboratory_productivity_bonus }
    else
        return nil
    end
    local ok, info = pcall(function()
        local slots = entity.module_inventory_size or 0
        local receiver = entity.effect_receiver
        if (slots == 0 or (receiver and receiver.uses_module_effects == false)) then
            return nil
        end
        local recipe = conf.type == "crafting-machine" and conf.recipe or nil
        local best, best_p = nil, 0
        for _, m in ipairs(modules) do
            if (module_allowed(m, entity.allowed_effects, entity.allowed_module_categories)
                    and (not recipe or module_allowed(m, recipe.allowed_effects, recipe.allowed_module_categories))) then
                local p = m.module_effects.productivity
                if (p > best_p) then
                    best, best_p = m, p
                end
            end
        end
        if (not best) then
            return nil
        end
        local fx = conf.module_effects or {}
        local function with_modules(modules)
            local copy = { modules = modules, beacons = fx.beacons, local_effect = fx.local_effect }
            local surface_effect = surface and surface.global_effect or nil
            return cutil.calculate_effects(receiver, copy, surface_effect, additional, max_effect, force,
                function() return true end).productivity
        end
        local p_none = with_modules({})
        local p_now = with_modules(fx.modules or {})
        local p_max = with_modules({ { module = best, quality = prototypes.quality.normal, count = slots } })
        if (p_max <= p_none + 1e-9) then
            return nil
        end
        return { slots = slots, module = best, p_none = p_none, p_now = p_now, p_max = p_max }
    end)
    return ok and info or nil
end

---@class BCE.ProdRow
---@field ri integer
---@field row BCE.Row
---@field have number buildings you have
---@field draw number item per second the group pulls, through everything it uses, now
---@field saves number item per second its modules save (or would) when every slot is filled
---@field modules integer modules to fill every slot
---@field per_module number saves / modules
---@field status "full" | "part" | "none"
---@field info BCE.ProdInfo
---@field products string[] what it makes (node ids)

--- What an item costs in the reported item, per unit made, through the plan's flows. A
--- building's draw goes to the products that make it run: the ones the plan uses all of
--- (byproducts it makes too much of come free). Solved by repeating until nothing changes.
---
--- It runs as a job, a little each tick (a big base takes about a second in one go). The job is
--- plain data, so it can sit in storage: start it, then step it until it says it's done.

--- Work units a step gets per tick. A big Py base takes about 140k for a report, about 0.1 s in
--- one go on a fast PC and about 1 s on a busy game: 2500 a tick spreads that over about a
--- second, at roughly half the frame rate while it runs.
detail.PROD_WORK_PER_TICK = 2500
--- Work units one group's module check counts for.
local PROD_INFO_WORK = 40
local MAX_PASSES = 200

---@class BCE.ProdJob
---@field id string
---@field scan BCE.Scan
---@field result BCE.Result
---@field force LuaForce
---@field phase "flows" | "charge" | "pass" | "modules" | "done"
---@field i integer
---@field work integer units done so far
---@field counted table<string, true>
---@field made table<string, number>
---@field used table<string, number>
---@field running integer[]
---@field any_children table<string, string[]>
---@field charge table<integer, { id: string, w: number }[]>
---@field cost table<string, number>
---@field draw table<integer, number>
---@field charged table<string, number>
---@field passes integer
---@field pull integer[] rows that pull on the item
---@field modules LuaItemPrototype[]? unlocked productivity modules
---@field list BCE.ProdRow[] the answer, best use of a module first
---@field pulling integer groups that pull on it at all
---@field settled boolean false: a loop kept the draws from settling

---@param scan BCE.Scan
---@param result BCE.Result
---@param id string
---@param force LuaForce
---@return BCE.ProdJob
function detail.productivity_start(scan, result, id, force)
    local counted = {}
    for _, e in ipairs(result.items) do
        if (e.mode == "counted") then
            counted[e.id] = true
        end
    end
    return { id = id, scan = scan, result = result, force = force, phase = "flows", i = 1, work = 0,
        counted = counted, made = {}, used = {}, running = {}, any_children = {}, charge = {},
        cost = { [id] = 1 }, draw = {}, charged = {}, passes = 0, pull = {}, list = {}, pulling = 0, settled = false }
end

---@param job BCE.ProdJob
---@param nid string
local function cost_of(job, nid)
    local c = job.cost[nid]
    if (c) then
        return c
    end
    local children = job.any_children[nid]
    if (children) then
        -- a fluid at any temperature: its temperatures, by how much of each the plan makes
        local sum, w = 0, 0
        for _, cid in ipairs(children) do
            local m = job.made[cid] or 0
            if (cid == job.id or job.counted[cid]) then
                sum = sum + m * (job.cost[cid] or 0)
            end
            w = w + m
        end
        return w > 0 and sum / w or 0
    end
    return 0
end

--- Step 1: what the plan makes and uses of each node, row by row.
---@param job BCE.ProdJob
local function step_flows(job, ri)
    local row, x = job.scan.rows[ri], job.result.row_x and job.result.row_x[ri]
    if (x and x > 0) then
        job.running[#job.running + 1] = ri
        local made, used = job.made, job.used
        for _, a in ipairs(row.amounts) do
            if (a.amount > 0) then
                made[a.id] = (made[a.id] or 0) + a.amount * x
            else
                used[a.id] = (used[a.id] or 0) - a.amount * x
                if (a.node.type == "any" and not job.any_children[a.id]) then
                    local list = {}
                    for _, child in ipairs(a.node.children or {}) do
                        list[#list + 1] = api.node.get_id(child)
                    end
                    job.any_children[a.id] = list
                end
            end
        end
    end
    return #row.amounts + 1
end

--- What a building takes of a fluid at any temperature comes out of its temperatures, by how
--- much of each the plan makes.
---@param job BCE.ProdJob
local function spread_any(job)
    local made, used = job.made, job.used
    for aid, children in pairs(job.any_children) do
        local total = 0
        for _, cid in ipairs(children) do
            total = total + (made[cid] or 0)
        end
        if (total > 0) then
            for _, cid in ipairs(children) do
                local m = made[cid] or 0
                if (m > 0) then
                    used[cid] = (used[cid] or 0) + used[aid] * m / total
                end
            end
        end
    end
end

--- Step 2: the products each running building is charged to, with their weights.
---@param job BCE.ProdJob
local function step_charge(job, ri)
    local row = job.scan.rows[ri]
    if (row.is_target) then
        return 1
    end
    local x = job.result.row_x[ri]
    local made, used = job.made, job.used
    local binding, all = {}, {}
    local wb, wa = 0, 0
    for _, a in ipairs(row.amounts) do
        if (a.amount > 0 and a.id ~= job.id and job.counted[a.id] and (used[a.id] or 0) > 0) then
            local u = math.min(1, used[a.id] / made[a.id])
            local w = a.amount * x
            if (u > 0.999) then
                binding[#binding + 1] = { id = a.id, w = w }
                wb = wb + w
            end
            all[#all + 1] = { id = a.id, w = w * u }
            wa = wa + w * u
        end
    end
    local list, total = binding, wb
    if (#binding == 0) then
        list, total = all, wa
    end
    if (total > 0) then
        for _, c in ipairs(list) do
            c.w = c.w / total
        end
        job.charge[ri] = list
    end
    return #row.amounts + 1
end

--- Step 3, repeated: one building's draw from what its inputs cost, passed on to its products.
---@param job BCE.ProdJob
local function step_pass(job, ri)
    local row, x = job.scan.rows[ri], job.result.row_x[ri]
    local total = 0
    for _, a in ipairs(row.amounts) do
        if (a.amount < 0) then
            local c = cost_of(job, a.id)
            if (c > 0) then
                total = total - a.amount * x * c
            end
        end
    end
    job.draw[ri] = total
    local charged = job.charged
    for _, c in ipairs(job.charge[ri] or {}) do
        charged[c.id] = (charged[c.id] or 0) + total * c.w
    end
    return #row.amounts + 1
end

--- The end of a pass: new costs. True when nothing changed.
---@param job BCE.ProdJob
---@return boolean
local function end_pass(job)
    local cost, charged = job.cost, job.charged
    local change = 0
    for nid, v in pairs(charged) do
        local new = v / job.used[nid]
        local old = cost[nid] or 0
        change = math.max(change, math.abs(new - old) / math.max(1, math.abs(new)))
        cost[nid] = new
    end
    for nid, old in pairs(cost) do
        if (nid ~= job.id and not charged[nid] and old ~= 0) then
            cost[nid] = nil
            change = 1
        end
    end
    job.charged = {}
    return change < 1e-9
end

--- Step 4: a group that pulls on the item, if it takes a productivity module.
---@param job BCE.ProdJob
local function step_modules(job, ri, surface)
    local d = job.draw[ri]
    local row = job.scan.rows[ri]
    local result = job.result
    local have = result.row_have and result.row_have[ri] or row.count_max
    local info = have > 0 and prod_info(row.conf, job.force, surface, job.modules) or nil
    if (info) then
        -- its draw without its own modules, then with every slot filled
        local none = d * (1 + info.p_now) / (1 + info.p_none)
        local saves = none - d * (1 + info.p_now) / (1 + info.p_max)
        local modules = info.slots * math.ceil(have - 1e-6)
        local status = "part"
        if (info.p_now >= info.p_max - 1e-6) then
            status = "full"
        elseif (info.p_now <= info.p_none + 1e-6) then
            status = "none"
        end
        local products = {}
        for _, a in ipairs(row.amounts) do
            if (a.amount > 0 and job.counted[a.id]) then
                products[#products + 1] = a.id
            end
        end
        job.list[#job.list + 1] = { ri = ri, row = row, have = have, draw = d, saves = saves, modules = modules,
            per_module = modules > 0 and saves / modules or 0, status = status, info = info, products = products }
    end
    return PROD_INFO_WORK
end

--- Runs a job for up to `budget` work units. True when it's done: the answer is in job.list,
--- job.pulling and job.settled.
---@param job BCE.ProdJob
---@param budget number
---@return boolean
function detail.productivity_step(job, budget)
    local rows = job.scan.rows
    local surface = game.surfaces[job.scan.surface_index]
    while (budget > 0 and job.phase ~= "done") do
        local used = 0
        if (job.phase == "flows") then
            if (job.i > #rows) then
                spread_any(job)
                job.phase, job.i = "charge", 1
            else
                used = step_flows(job, job.i)
                job.i = job.i + 1
            end
        elseif (job.phase == "charge") then
            if (job.i > #job.running) then
                job.phase, job.i = "pass", 1
            else
                used = step_charge(job, job.running[job.i])
                job.i = job.i + 1
            end
        elseif (job.phase == "pass") then
            if (job.i > #job.running) then
                job.passes = job.passes + 1
                job.i = 1
                local still = end_pass(job)
                if (still or job.passes >= MAX_PASSES) then
                    job.settled = still
                    for _, ri in ipairs(job.running) do
                        if (job.draw[ri] > 1e-9) then
                            job.pull[#job.pull + 1] = ri
                        end
                    end
                    job.pulling = #job.pull
                    job.modules = unlocked_prod_modules(job.force)
                    job.phase = "modules"
                end
            else
                used = step_pass(job, job.running[job.i])
                job.i = job.i + 1
            end
        elseif (job.phase == "modules") then
            if (job.i > #job.pull) then
                table.sort(job.list, function(a, b)
                    if (a.per_module ~= b.per_module) then return a.per_module > b.per_module end
                    return a.ri < b.ri
                end)
                -- the working tables aren't needed any more
                job.made, job.used, job.charge, job.cost, job.charged, job.any_children = nil, nil, nil, nil, nil, nil
                job.phase = "done"
            else
                used = step_modules(job, job.pull[job.i], surface)
                job.i = job.i + 1
            end
        end
        used = math.max(used, 1)
        budget = budget - used
        job.work = job.work + used
    end
    return job.phase == "done"
end

--- All of it at once (tests).
---@param scan BCE.Scan
---@param result BCE.Result
---@param id string
---@param force LuaForce
---@return BCE.ProdRow[] list
---@return integer pulling
---@return boolean settled
---@return integer work
function detail.productivity(scan, result, id, force)
    local job = detail.productivity_start(scan, result, id, force)
    detail.productivity_step(job, math.huge)
    return job.list, job.pulling, job.settled, job.work
end

return detail
