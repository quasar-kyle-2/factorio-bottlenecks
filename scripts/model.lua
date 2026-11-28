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

--- Waste items: what burning a fuel leaves behind, when nothing refills it into that fuel (ash,
--- spent nuclear fuel). What a building burns is dropped from its amounts (ignored_tags), so
--- this is about recipes: they count waste like any other item, but waste nothing makes is
--- never given a supply. Empty canisters, used batteries, used animals and the like are
--- refilled or recharged one for one into their fuel, so they aren't waste. Turning 10 ash into
--- 1 coal dust is reprocessing, not refilling: ash is still waste.
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

--- Water at its default temperature (15°), or a temperature range that includes it: free and
--- worthless, like an offshore pump's.
---@param node Rates.Node
---@return boolean
local function is_water15(node)
    if (node.type == "fluid" and node.fluid and node.fluid.name == "water") then
        return node.temperature == node.fluid.default_temperature
    end
    local details = node.type == "any" and node.details
    if (details and details.type == "any-fluid" and details.fluid and details.fluid.name == "water") then
        local d = details.fluid.default_temperature
        return (details.min_temperature == nil or details.min_temperature <= d)
            and (details.max_temperature == nil or details.max_temperature >= d)
    end
    return false
end

--- Unlimited: power, heat, fuel, pollution and default-temperature water. Water at any other
--- temperature and steam are counted, and so is recipe waste (ash a recipe makes): they take
--- buildings to make. (track_steam false keeps steam unlimited, for the remote interface.)
---@param node Rates.Node
---@param track_steam boolean?
---@return boolean
local function is_ignored_node(node, track_steam)
    local t = node.type
    if (ignored_node_types[t]) then
        return true
    end
    if (t == "fluid") then
        if (node.fluid.name == "water") then
            return is_water15(node)
        end
        return fluid_ignored(node.fluid.name, track_steam)
    end
    if (t == "any") then
        local details = node.details
        if (details) then
            if (ignored_any_types[details.type]) then
                return true
            end
            if (details.type == "any-fluid" and details.fluid and details.fluid.name == "water") then
                return is_water15(node)
            end
            if (details.type == "any-fluid" and details.fluid and fluid_ignored(details.fluid.name, track_steam)) then
                return true
            end
        end
    end
    return false
end

--- Fuel categories with few fuels (drill heads, fuel rods) are a building's own supply, made
--- for it: such a fuel is traced as an ordinary input. Any other fuel (coal and the like, liquid
--- fuels) is the player's free choice and stays unlimited.
local SPECIAL_FUEL_MAX = 8
local fuel_count = nil ---@type table<string, integer>?

---@param item LuaItemPrototype
---@return boolean
local function special_fuel(item)
    if (not fuel_count) then
        fuel_count = {}
        for _, it in pairs(prototypes.item) do
            local ok, cats = pcall(function() return it.fuel_categories end)
            if (ok and cats and (it.fuel_value or 0) > 0) then
                for _, c in pairs(cats) do
                    fuel_count[c] = (fuel_count[c] or 0) + 1
                end
            end
        end
    end
    local ok, cats = pcall(function() return item.fuel_categories end)
    if (not ok or not cats or #cats == 0) then
        return false
    end
    for _, c in pairs(cats) do
        if ((fuel_count[c] or 0) > SPECIAL_FUEL_MAX) then
            return false
        end
    end
    return true
end

---@param amounts Rates.Configuration.Amount[]
---@return { id: string, node: Rates.Node, amount: number }[]
local function sum_amounts(amounts)
    local by_id, list = {}, {}
    for _, amount in ipairs(amounts) do
        if (ignored_tags[amount.tag] and not (amount.tag == "energy-source-input" and amount.node.type == "item"
                and amount.node.item and special_fuel(amount.node.item))) then
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
---@field rent number running cost of one building per second (running_cost)

---@class BCE.Scan
---@field surface_index integer
---@field rows BCE.Row[]
---@field scanned_entities integer
---@field target_entities integer
---@field target_entities_without_conf integer
---@field planned_changes integer ghosts, queued upgrades and pending module requests counted in
---@field lane_rate number? items per second on one lane of the best belt unlocked (model.lane_rate)

--- Running cost ("rent", ongoing, per building-second), YAFC's definition of work: 0.02 per item
--- and 0.0005 per fluid unit going in or out, and 0.1 per MJ of energy (electricity, heat, fuel).
--- Default-temperature water costs nothing to handle. A special fuel (special_fuel) is traced
--- like an input, so it pays handling.
---@param raw Rates.Configuration.Amount[] from get_production, energy included
---@return number
local function running_cost(raw)
    local handling, joules = 0, 0
    for _, a in ipairs(raw) do
        local t = a.node.type
        if (a.tag == "energy-source-input") then
            if (t == "item" and a.node.item) then
                if (special_fuel(a.node.item)) then
                    handling = handling + math.abs(a.amount) * 0.02
                else
                    joules = joules - a.amount * (a.node.item.fuel_value or 0)
                end
            elseif (a.fuel_usage) then
                joules = joules + a.fuel_usage
            elseif (t == "fluid" and a.node.fluid and (a.node.fluid.fuel_value or 0) > 0) then
                joules = joules - a.amount * a.node.fluid.fuel_value
            else
                joules = joules - a.amount
            end
        elseif (a.tag ~= "energy-source-output" and a.tag ~= "pollution" and t ~= "map-entity" and not is_water15(a.node)) then
            if (t == "item") then
                handling = handling + math.abs(a.amount) * 0.02
            elseif (t == "fluid" or t == "any") then
                handling = handling + math.abs(a.amount) * 0.0005
            end
        end
    end
    return handling + joules / 1e6 * 0.1
end

--- A recipe that is only for show: hidden, and makes something out of nothing. Pyanodon's dig
--- sites run one (4000 nexelit ore per second) while their digosaurs really walk out and mine
--- the ore by script, at a rate nothing on the building tells. Its products are dropped: the
--- item gets a supply instead, capped at what the factory really made in the last hour (see
--- model.build).
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

-- ---------------------------------------------------------------------------
-- Mega-farms (Pyanodon's)
--
-- A mega-farm is a rocket silo whose recipe's products never come out. Each craft launches an
-- invisible rocket carrying one seed item (replicator-mova), and Py's script then spreads the
-- crop as a resource over the 23 x 23 tiles in front of the farm, where harvesters and flora
-- collectors (mining drills) mine it. sw-rates-lib gives a silo a send-to-orbit product instead,
-- so a mega-farm is turned into what it does: per launch it uses a seed item and makes the crop's
-- resource, the same node the drills mine. Py's own table (mod-data "pyanodons", smart_farm)
-- says which recipe grows which crop, from which seed, and how much per tile.

--- Tiles a launch covers (Py: x and y from -11 to 11 around the crop area's centre).
local FARM_TILES = 23 * 23
--- The crop area's centre, from the farm's position, and how far out Py looks for harvesters.
local FARM_OFFSET_Y = -15
local FARM_REACH = 12

local farm_cache = nil ---@type table<string, { launch: LuaItemPrototype, resource: LuaEntityPrototype, yield: number }>?

--- Recipe name -> what a launch of it needs and grows: its seed item, the crop's resource and
--- the amount per tile. Empty without Pyanodon's.
local function farm_recipes()
    if (farm_cache) then
        return farm_cache
    end
    farm_cache = {}
    local ok, crops = pcall(function() return prototypes.mod_data["pyanodons"].data.smart_farm.crops end)
    if (not ok or type(crops) ~= "table") then
        return farm_cache
    end
    for launch, crop in pairs(crops) do
        local item = prototypes.item[launch]
        local resource = type(crop) == "table" and type(crop.resource) == "string" and prototypes.entity[crop.resource]
        if (item and resource and type(crop.recipes) == "table") then
            for name, yield in pairs(crop.recipes) do
                if (type(yield) == "number" and yield > 0) then
                    farm_cache[name] = { launch = item, resource = resource, yield = yield }
                end
            end
        end
    end
    return farm_cache
end

--- A mega-farm's amounts as what it really does: its send-to-orbit product becomes one seed item
--- used per launch and the crop's resource made. Any other configuration's are unchanged.
---@param conf Rates.Configuration
---@param raw Rates.Configuration.Amount[]?
---@return Rates.Configuration.Amount[]?
local function farm_amounts(conf, raw)
    local e = raw and conf.type == "crafting-machine" and conf.entity
    local farm = e and e.type == "rocket-silo" and conf.recipe and farm_recipes()[conf.recipe.name]
    if (not farm) then
        return raw
    end
    local cap = 1
    pcall(function() cap = e.get_inventory_size(defines.inventory.rocket_silo_rocket, conf.quality) end)
    if (not cap or cap <= 0) then
        cap = 1
    end
    local out, launches = {}, 0
    for _, a in ipairs(raw) do
        if (a.node.type == "send-to-orbit") then
            launches = launches + a.amount / cap
        else
            out[#out + 1] = a
        end
    end
    if (launches > 0) then
        local normal = prototypes.quality["normal"]
        out[#out + 1] = { tag = "ingredient", node = api.node.create.item(farm.launch, normal), amount = -launches }
        out[#out + 1] = { tag = "product", node = api.node.create.map_entity(farm.resource, normal),
            amount = launches * farm.yield * FARM_TILES }
    end
    return out
end

--- Harvesters in a mega-farm with no crop under them right now (it grows back with the next
--- launch): unit number -> the crop's resource, so they count as mining it.
---@param list LuaEntity[]
---@param surface LuaSurface
---@param force LuaForce
---@return table<integer, LuaEntityPrototype>
local function farm_drills(list, surface, force)
    local result = {}
    if (not next(farm_recipes())) then
        return result
    end
    for _, entity in ipairs(list) do
        if (entity.type == "rocket-silo") then
            local ok, recipe = pcall(entity.get_recipe)
            local farm = ok and recipe and farm_recipes()[recipe.name]
            if (farm) then
                local x, y = entity.position.x, entity.position.y + FARM_OFFSET_Y
                local drills = surface.find_entities_filtered { type = "mining-drill", force = force,
                    area = { { x - FARM_REACH, y - FARM_REACH }, { x + FARM_REACH, y + FARM_REACH } } }
                for _, d in ipairs(drills) do
                    if (d.unit_number and not d.mining_target
                            and d.prototype.resource_categories[farm.resource.resource_category]) then
                        result[d.unit_number] = farm.resource
                    end
                end
            end
        end
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Rocket cargo
--
-- A rocket silo's rocket carries items whose launch brings something back (Pyanodon's tholin
-- capsule returns 500 filled tholin vessels, a space dingrit its return, a satellite destabilized
-- toxirus). sw-rates-lib counts the launch on its own (send-to-orbit), which a scan never sees,
-- so a silo is given what its rocket carries: the cargo is used and the launch products made.
-- The cargo is what's in the rocket now, or, while it's empty between launches, what was in it
-- the last time a scan saw it (storage.silo_cargo).

--- What a silo's rocket carries, as item name and quality -> its share of the rocket's slots, and
--- a key for it ("" when nothing is known). Only items whose launch brings something back.
---@param entity LuaEntity
---@return table<string, { item: LuaItemPrototype, quality: LuaQualityPrototype, share: number }>?, string
local function silo_cargo(entity)
    if (entity.type ~= "rocket-silo") then
        return nil, ""
    end
    local counts = nil ---@type table<string, number>?
    local ok, inv = pcall(entity.get_inventory, defines.inventory.rocket_silo_rocket)
    if (ok and inv) then
        for _, c in ipairs(inv.get_contents()) do
            local item = prototypes.item[c.name]
            if (item and item.rocket_launch_products and #item.rocket_launch_products > 0) then
                counts = counts or {}
                local k = c.name .. "/" .. (c.quality or "normal")
                counts[k] = (counts[k] or 0) + c.count / item.stack_size
            end
        end
    end
    storage.silo_cargo = storage.silo_cargo or {}
    if (counts) then
        storage.silo_cargo[entity.unit_number] = counts
    else
        counts = storage.silo_cargo[entity.unit_number]
    end
    if (not counts) then
        return nil, ""
    end
    local total, keys = 0, {}
    for k, n in pairs(counts) do
        total = total + n
        keys[#keys + 1] = k
    end
    table.sort(keys)
    local cargo = {}
    for _, k in ipairs(keys) do
        local name, quality = k:match("^(.*)/([^/]*)$")
        local item, q = prototypes.item[name], prototypes.quality[quality]
        if (item and q and total > 0) then
            cargo[k] = { item = item, quality = q, share = counts[k] / total }
        end
    end
    if (not next(cargo)) then
        return nil, ""
    end
    return cargo, table.concat(keys, ",")
end

--- A rocket silo's amounts with its cargo: each rocket slot launched (send-to-orbit) uses a stack
--- of the cargo and makes what its launch brings back.
---@param raw Rates.Configuration.Amount[]?
---@param cargo table<string, { item: LuaItemPrototype, quality: LuaQualityPrototype, share: number }>?
---@return Rates.Configuration.Amount[]?
local function cargo_amounts(raw, cargo)
    if (not raw or not cargo) then
        return raw
    end
    local out, slots = {}, 0
    for _, a in ipairs(raw) do
        if (a.node.type == "send-to-orbit") then
            slots = slots + a.amount
        else
            out[#out + 1] = a
        end
    end
    if (slots <= 0) then
        return raw
    end
    for _, c in pairs(cargo) do
        local n = slots * c.share * c.item.stack_size
        out[#out + 1] = { tag = "ingredient", node = api.node.create.item(c.item, c.quality), amount = -n }
        for _, p in ipairs(c.item.rocket_launch_products) do
            local each = (p.amount or ((p.amount_min or 0) + (p.amount_max or 0)) / 2) * (p.probability or 1)
                + (p.extra_count_fraction or 0)
            local proto = prototypes.item[p.name] -- launch products are items
            if (proto and each > 0) then
                out[#out + 1] = { tag = "product", node = api.node.create.item(proto, c.quality), amount = n * each }
            end
        end
    end
    return out
end

--- What the force has researched and unlocked, as one string: research, recipes enabled and
--- their productivity, and the force-wide bonuses that change what buildings make. A warm
--- Refresh (model.warm_build) needs it unchanged. Pyanodon's TURD choices change it too: they
--- research hidden technologies and enable or disable recipes.
---@param force LuaForce
---@return string
function model.tech_signature(force)
    local researched, levels = 0, 0
    for _, tech in pairs(force.technologies) do
        if (tech.researched) then
            researched = researched + 1
        end
        levels = levels + (tech.level or 0)
    end
    local enabled, prod, h = 0, 0, 0
    for name, recipe in pairs(force.recipes) do
        if (recipe.enabled) then
            enabled = enabled + 1
            -- order-free hash of which recipes are enabled
            local x = 0
            for i = 1, #name, 3 do
                x = (x * 31 + string.byte(name, i)) % 1000003
            end
            h = (h + x) % 1000000007
        end
        prod = prod + (recipe.productivity_bonus or 0)
    end
    local bonus = 0
    pcall(function()
        bonus = force.mining_drill_productivity_bonus + 7 * force.laboratory_speed_modifier
            + 13 * force.laboratory_productivity_bonus
    end)
    return string.format("%d/%d/%d/%d/%.12g/%.12g", researched, levels, enabled, h, prod, bonus)
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
    local function get_row(key, conf, is_target, cargo)
        local row = rows_by_key[key]
        if (not row) then
            local annotations = api.configuration.get_annotations(conf)
            local amounts = api.configuration.get_production(conf, {
                force = force,
                surface = surface,
                use_pollution = use_pollution,
                annotations = annotations,
            })
            amounts = cargo_amounts(farm_amounts(conf, amounts), cargo)
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
                rent = running_cost(amounts or {}),
            }
            rows_by_key[key] = row
            rows[#rows + 1] = row
        end
        return row
    end

    local farm_drill = farm_drills(list, surface, force)
    local target_entities, target_without_conf = 0, 0
    for _, entity in ipairs(list) do
        local is_target = target_ids[entity.unit_number] == true
        if (is_target) then
            target_entities = target_entities + 1
        end
        local inputs = ctx and analyzer.get_entity_inputs(ctx, entity) or nil
        local conf = api.configuration.get_from_entity(entity, { use_ghosts = true, analyzer_inputs = inputs })
        if (conf and conf.type == "mining-drill" and not conf.resource and farm_drill[entity.unit_number]) then
            conf.resource = farm_drill[entity.unit_number]
        end
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
                local cargo, cargo_key = nil, ""
                if (conf.type == "crafting-machine" and not (conf.recipe and farm_recipes()[conf.recipe.name])) then
                    cargo, cargo_key = silo_cargo(entity)
                end
                if (cargo) then
                    key = key .. "|cargo=" .. cargo_key
                end
                local row = get_row(key, conf, is_target, cargo)
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
        lane_rate = model.lane_rate(force),
        use_analyzer = use_analyzer and true or false,
        tech_sig = model.tech_signature(force),
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
    if (is_ignored_node(e.node, track_steam)) then
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
-- already have first, and only goes past them where it has to, with as little hassle as possible.
--
--   variables: x_r = buildings running row r (targets: up to speed × count). Other rows have
--              two columns with the same coefficients: up to the buildings you have (cheap),
--              and any amount beyond that (expensive)
--   items:     net production >= 0 (counted items); unlimited and unmade items have no row.
--              Items brought in from outside the model (nothing makes them, or dig sites make
--              them by script) get a supply column, capped at what the factory made in the last
--              hour (or what the plan uses, if more): model.cap_supplies, after a first solve
--   objective: run the targets at their speed first; then keep the hassle of the extra
--              buildings low (model.clone_hassle: a clone of a group you have costs its width,
--              a quarter of its connections since its belts and pipes are there already, plus
--              belt lanes beyond the first and its power in full); then, between plans of about
--              the same hassle, the lowest rent (running cost) of every building running, yours
--              included. Your own buildings cost nothing but their rent.
--
-- Per item: needed = what the chain uses at those rates; can make = what the buildings it uses
-- to make the item would make at 100% with the buildings you have, plus its supply. Coverage =
-- can make ÷ needed: below 100% the item is short at the chosen speeds, and it runs out once
-- the targets are turned up past that fraction of them.
--
-- Projects (model.whatif_step): recipes you don't use for your targets yet, each built fresh in a
-- building type you can build. The solved plan's item prices pick the promising ones; those are added
-- to the solved model as columns locked at 0, and each is unlocked alone on a copy of it, to see
-- how much hassle it saves.

local EPS = 1e-7
local W_TARGET = 1e4
--- per unit of hassle, for each building beyond the ones you have
local W_OVER = 1e-2
--- per unit of rent (running cost per second) of every building running, yours or extra: only
--- decides between plans of about the same hassle (100 rent per second weighs 0.1 hassle)
local W_RENT = 1e-5
--- Rent floor, so no building runs for free.
local MIN_RENT = 1e-2
--- Buildings running less than this are solver noise.
local RUN_TOL = 1e-6
--- Items needed or made slower than this per second are solver noise.
local NEED_TOL = 1e-4
--- Upper bound of a supply column until it is capped.
local SUPPLY_OPEN = 1e9

--- Hassle of the power plant behind one MW of electricity a new building draws: flat, and
--- conservative for a late Pyanodon's base (about 0.03 there: a coal power plant MK03 and its
--- share of heat exchangers and turbine make about 450 MW).
local HASSLE_PER_MW = 0.05
--- Items per second on one lane of a yellow belt: the lane size before any belt is unlocked.
local YELLOW_LANE = 7.5

--- Items per second on one lane of the fastest belt the force has unlocked (yellow if none).
--- Read once per scan.
---@param force LuaForce
---@return number
function model.lane_rate(force)
    local best = YELLOW_LANE
    pcall(function()
        for _, belt in pairs(prototypes.get_entity_filtered { { filter = "type", type = "transport-belt" } }) do
            local rate = belt.belt_speed * 480 / 2
            if (rate > best and not belt.hidden) then
                for _, place in ipairs(belt.items_to_place_this or {}) do
                    local name = type(place) == "table" and place.name or place
                    local made = prototypes.get_recipe_filtered { { filter = "has-product-item",
                        elem_filters = { { filter = "name", name = name } } } }
                    for rname, _ in pairs(made) do
                        local r = force.recipes[rname]
                        if (r and r.enabled) then
                            best = rate
                            break
                        end
                    end
                    if (best == rate) then
                        break
                    end
                end
            end
        end
    end)
    return best
end

--- The parts of a building's hassle (see building_cost and model.clone_hassle).
---@param row { conf: Rates.Configuration, amounts: { node: Rates.Node, amount: number }[] }
---@param lane number? items per second on one belt lane (model.lane_rate)
---@return number width
---@return number links one per item, fluid, heat pipe or fuel it needs (see building_cost)
---@return number lanes half of the belt lanes beyond the first that its items need
---@return number power hassle of the power it draws
local function hassle_parts(row, lane)
    lane = lane or YELLOW_LANE
    local conf = row.conf
    if (conf and conf.type == "meta" and conf.children and conf.children[1]) then
        conf = conf.children[1]
    end
    local proto = conf and conf.entity
    local width, links, lanes, power = 3, 0, 0, 0
    if (proto) then
        pcall(function()
            width = proto.tile_width or 3
            if (proto.heat_energy_source_prototype) then
                links = links + 1
            end
            if (proto.burner_prototype) then
                links = links + 2
            elseif (proto.fluid_energy_source_prototype) then
                links = links + 1
            end
        end)
        pcall(function()
            local source = proto.electric_energy_source_prototype
            if (source) then
                -- base draw: no modules, no beacons
                local per_tick = proto.get_max_energy_usage(conf.quality) + (source.drain or 0)
                power = HASSLE_PER_MW * per_tick * 60 / 1e6
            end
        end)
    end
    for _, a in ipairs(row.amounts) do
        local t = a.node.type
        if ((t == "item" or t == "fluid" or t == "any") and not (a.amount > 0 and is_water15(a.node))) then
            links = links + 1
            if (t == "item") then
                -- the first lane is the link itself; each further lane is half a belt
                lanes = lanes + 0.5 * math.max(0, math.abs(a.amount) / lane - 1)
            end
        end
    end
    return width, links, lanes, power
end

--- What a new building of a row takes to fit in (its hassle): its width in tiles, a belt lane,
--- pipe or inserter for each item and fluid it uses or makes, a heat pipe if it runs on heat,
--- and fuel (plus its burnt result) if it burns something. An item needing more than one lane
--- of the best belt you have pays half for each further lane, since a lane is half a belt
--- (fractions too: neighbors share them). The
--- power it draws pays HASSLE_PER_MW for the plant behind it. Default-temperature water it
--- makes costs nothing: it can be voided or left. Whatever you already have of it.
---@param row { conf: Rates.Configuration, amounts: { node: Rates.Node, amount: number }[] }
---@param lane number? items per second on one belt lane (model.lane_rate)
---@return number
local function building_cost(row, lane)
    local width, links, lanes, power = hassle_parts(row, lane)
    return width + links + lanes + power
end

--- Hassle of one more building of a group you have: its width, plus a quarter of its links,
--- since its belts and pipes are already there. Lanes beyond the first and power are paid in
--- full: a full belt or power plant doesn't get emptier because the group exists.
---@param row BCE.Row
---@param lane number? items per second on one belt lane (model.lane_rate)
---@return number
function model.clone_hassle(row, lane)
    local width, links, lanes, power = hassle_parts(row, lane)
    return width + 0.25 * links + lanes + power
end

--- A row's columns in the model: "target" (its buildings up to speed × count, rewarded, plus
--- an unrewarded twin), "have" (up to the buildings you have, at their rent, plus a twin for any
--- beyond them at their hassle) or "new" (none yet: one column at hassle).
---@param row BCE.Row
---@param have number buildings you have of it (meta groups shared out)
---@param speeds table<string, number>
---@param lane number?
---@return string kind
---@return number? upper of the first column (nil: none)
---@return number cost of the first column
---@return number? cost of the twin (nil: no twin)
local function row_spec(row, have, speeds, lane)
    if (row.is_target) then
        local count = math.max(1, total_count(row))
        return "target", (speeds[row.key] or 1) * row.count_max, -W_TARGET / count, 0
    end
    local rent = W_RENT * math.max(row.rent or 0, MIN_RENT)
    local over = W_OVER * model.clone_hassle(row, lane) + rent
    if (have > 0) then
        return "have", have, rent, over
    end
    return "new", nil, over, nil
end

---@param t table
---@return table
local function copy_flat(t)
    local r = {}
    for k, v in pairs(t) do
        r[k] = v
    end
    return r
end

--- Buildings you have of each kept row: a machine that switches between recipes counts evenly
--- toward each of them.
---@param rows BCE.Row[]
---@param kept integer[]
---@return table<integer, number>
local function have_counts(rows, kept)
    local meta_children = {} ---@type table<string, integer>
    for _, ri in ipairs(kept) do
        for meta_id, _ in pairs(rows[ri].count_groups or {}) do
            meta_children[meta_id] = (meta_children[meta_id] or 0) + 1
        end
    end
    local have = {}
    for _, ri in ipairs(kept) do
        local row = rows[ri]
        local h = row.count_max
        for meta_id, k in pairs(row.count_groups or {}) do
            h = h + k / meta_children[meta_id]
        end
        have[ri] = h
    end
    return have
end

---@class BCE.Prep
---@field nodes table
---@field modes table<string, string>
---@field defaults table<string, string>
---@field supply_ids table<string, true> brought in from outside the model: gets a supply column
---@field kept integer[] scan rows feeding the targets
---@field need_sorted string[] items with a balance row
---@field node_con table<string, integer> item -> its balance row
---@field track_steam boolean

--- Which items are counted and which rows feed the targets: everything model.build needs before
--- the solver's columns.
---@param scan BCE.Scan
---@param overrides table<string, string> node id -> "ignored" (treated as unlimited)
---@param track_steam boolean?
---@return BCE.Prep
function model.prepare(scan, overrides, track_steam)
    local rows = scan.rows
    local nodes = collect_nodes(rows)

    local modes, defaults = {}, {} ---@type table<string, string>, table<string, string>
    for id, e in pairs(nodes) do
        local d = default_mode(id, e, track_steam, scan.fake_items)
        defaults[id] = d
        modes[id] = (d == "counted" and overrides[id] == "ignored") and "ignored" or d
    end
    -- brought in from outside the model (dig sites, script deliveries, hand-fed): counted, with
    -- a supply column. Waste nothing makes is used up, not brought in.
    local supply_ids = {} ---@type table<string, true>
    for id, e in pairs(nodes) do
        local t = e.node.type
        local brought_in = (modes[id] == "free" and (t == "item" or t == "fluid")
                and not (t == "item" and waste_items()[e.node.item.name]))
            or (scan.fake_items and scan.fake_items[id] and modes[id] ~= "ignored")
        if (brought_in and overrides[id] ~= "ignored") then
            modes[id] = "counted"
            supply_ids[id] = true
        end
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
    for i, id in ipairs(need_sorted) do
        node_con[id] = i
    end
    return {
        nodes = nodes,
        modes = modes,
        defaults = defaults,
        supply_ids = supply_ids,
        kept = kept,
        need_sorted = need_sorted,
        node_con = node_con,
        track_steam = track_steam or false,
    }
end

---@param scan BCE.Scan
---@param overrides table<string, string> node id -> "ignored" (treated as unlimited)
---@param track_steam boolean?
---@param speeds table<string, number> target row key -> speed (1 = 100%); missing = 100%
---@param prep BCE.Prep? from model.prepare with the same scan, overrides and track_steam
function model.build(scan, overrides, track_steam, speeds, prep)
    local rows = scan.rows
    prep = prep or model.prepare(scan, overrides, track_steam)
    local nodes, kept, need_sorted, node_con = prep.nodes, prep.kept, prep.need_sorted, prep.node_con
    local lane = scan.lane_rate

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

    local have_of = have_counts(rows, kept)

    local row_var = {} ---@type table<integer, integer>
    -- Each target group also has an unrewarded twin column: lowering its speed hands the excess
    -- to the twin without changing anything else, so the solver can continue from there.
    -- For other rows the twin is the expensive column: buildings beyond the ones you have.
    local twin_var = {} ---@type table<integer, integer>
    -- row key -> its columns, for a warm Refresh (model.warm_build)
    local col_of = {} ---@type table<string, { v: integer, t: integer? }>
    local n_targets = 0
    for _, ri in ipairs(kept) do
        local row = rows[ri]
        local kind, ub, cv, ct = row_spec(row, have_of[ri], speeds, lane)
        if (kind == "target") then
            n_targets = n_targets + 1
        end
        local v = var(ub)
        cost[v] = cv
        row_var[ri] = v
        if (ct) then
            local t = var(nil)
            cost[t] = (ct ~= 0) and ct or nil
            twin_var[ri] = t
        end
        col_of[row.key] = { v = v, t = twin_var[ri] }
    end

    -- item balances: net production >= 0. Every row gets a tiny distinct offset: many balances
    -- are exactly 0, and that many tied rows make the simplex stall.
    for _ in ipairs(need_sorted) do
        m = m + 1
        b[m] = EPS * (1 + ((m * 7919) % 1000) / 1000)
        sign[m] = -1
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

    -- supplies of items brought in, free until capped
    local supply_vars = {} ---@type table<string, integer>
    for id, _ in pairs(prep.supply_ids) do
        local i = node_con[id]
        if (i) then
            local v = var(SUPPLY_OPEN)
            cost[v] = 0
            set(i, v, 1)
            supply_vars[id] = v
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
        modes = prep.modes,
        defaults = prep.defaults,
        nodes = nodes,
        n_targets = n_targets,
        n_constraints = m,
        track_steam = track_steam or false,
        supply_vars = supply_vars,
        -- what a warm Refresh must match
        col_of = col_of,
        need_sorted = need_sorted,
        overrides = copy_flat(overrides),
        surface_index = scan.surface_index,
        lane = lane,
        use_analyzer = scan.use_analyzer,
        tech_sig = scan.tech_sig,
        target_sig = model.target_signature(scan, kept),
        warm_chain = 0,
        cold = true,
    }
end

--- The target groups and their counts, as one string.
---@param scan BCE.Scan
---@param kept integer[]
---@return string
function model.target_signature(scan, kept)
    local list = {}
    for _, ri in ipairs(kept) do
        local row = scan.rows[ri]
        if (row.is_target) then
            list[#list + 1] = row.key .. "#" .. row.count_max
        end
    end
    table.sort(list)
    return table.concat(list, "|")
end

-- ---------------------------------------------------------------------------
-- Warm Refresh
--
-- A Refresh after a few changes to the factory (buildings built, removed, given other modules or
-- recipes) continues from the last answer: the model stays, its columns are matched to the new
-- scan's building groups by key, bounds change for groups whose count changed, groups that are
-- gone are locked at 0 and new ones are added (lp.extend), and the solver brings the solution
-- back within the new bounds (dual simplex) and optimizes again. The answer is the same as from
-- scratch (the same optimum; between plans that tie exactly, it may pick another one).
--
-- It starts from scratch instead when anything else changed (model.warm_build says why): the
-- item balances, unlimited items, supplies, targets, research or unlocked recipes (Pyanodon's
-- TURD choices included), force bonuses, belts, the surface, the analyzer setting, what a kept
-- group makes or costs, or too much at once. It also gives up for a cold start when the warm
-- solve takes more than a quarter of the last cold solve's work (control.lua).

--- Groups that may change at once before a cold start is used: a few times what one gameplay
--- session between Refreshes changes. Measured on a large Py base (2026-11-27): 300 changed
--- groups warm in about 1 s against about 90 s cold.
local WARM_MAX_CHANGED = 300
local WARM_MAX_CHANGED_SHARE = 0.25
--- Columns left locked (gone groups, tried projects) before the model is rebuilt cold.
local WARM_MAX_DEAD_SHARE = 0.25
--- Warm Refreshes in a row before one cold one, so nothing builds up.
local WARM_MAX_CHAIN = 25
--- Share of the last cold solve's work a warm Refresh may take (control.lua)
model.WARM_WORK_SHARE = 0.25

---@param a number
---@param b number
local function close(a, b)
    if (a == b) then
        return true
    end
    local m = math.max(math.abs(a), math.abs(b))
    return math.abs(a - b) <= 1e-12 * m
end

--- The column a row gets: its amounts on the item balances (sign as in model.build).
---@param row BCE.Row
---@param node_con table<string, integer>
---@return table<integer, number>
local function row_column(row, node_con)
    local c = {}
    for _, a in ipairs(row.amounts) do
        local i = node_con[a.id]
        if (i) then
            local v = (c[i] or 0) - a.amount
            c[i] = (v ~= 0) and v or nil
        end
    end
    return c
end

---@param A table<integer, number>
---@param c table<integer, number>
local function same_column(A, c)
    for i, a in pairs(A) do
        if (not c[i] or not close(a, c[i])) then
            return false
        end
    end
    for i, _ in pairs(c) do
        if (not A[i]) then
            return false
        end
    end
    return true
end

--- Building types a project can be built in: crafting machines that take a recipe you choose
--- (a rocket silo too: Pyanodon's mega-farms are silos; the real one has a fixed recipe).
local crafter_types = { ["assembling-machine"] = true, ["furnace"] = true, ["rocket-silo"] = true }

--- What the search for project candidates depends on beyond research, recipes, bonuses, belts
--- and the item balances (all the same after a warm Refresh): the building types you have, the
--- recipes you use and the items set to unlimited. The same sig means the same candidates.
---@param scan BCE.Scan
---@param kept integer[]
---@param modes table<string, string>
---@return { entity: LuaEntityPrototype, quality: LuaQualityPrototype? }[] entities
---@return table<string, true> used recipe names
---@return string sig
local function candidate_inputs(scan, kept, modes)
    local rows = scan.rows
    local entities, seen = {}, {}
    for _, row in ipairs(rows) do
        local conf = row.conf
        if (conf and conf.type == "meta" and conf.children and conf.children[1]) then
            conf = conf.children[1]
        end
        local e = conf and conf.type == "crafting-machine" and conf.entity
        if (e and crafter_types[e.type] and not e.fixed_recipe and not seen[e.name]) then
            seen[e.name] = true
            entities[#entities + 1] = { entity = e, quality = conf.quality }
        end
    end
    table.sort(entities, function(a, b) return a.entity.name < b.entity.name end)
    local used = {}
    for _, ri in ipairs(kept) do
        local conf = rows[ri].conf
        if (conf and conf.type == "meta" and conf.children) then
            for _, ch in ipairs(conf.children) do
                if (ch.recipe) then
                    used[ch.recipe.name] = true
                end
            end
        elseif (conf and conf.recipe) then
            used[conf.recipe.name] = true
        end
    end
    local parts = {}
    for _, e in ipairs(entities) do
        parts[#parts + 1] = "e:" .. e.entity.name .. "/" .. (e.quality and e.quality.name or "")
    end
    local names = {}
    for name, _ in pairs(used) do
        names[#names + 1] = "r:" .. name
    end
    for id, m in pairs(modes) do
        if (m == "ignored") then
            names[#names + 1] = "i:" .. id
        end
    end
    table.sort(names)
    for _, s in ipairs(names) do
        parts[#parts + 1] = s
    end
    return entities, used, table.concat(parts, "|")
end

--- Continues a solved model (built) for a new scan of the same factory: see "Warm Refresh".
--- On false the caller builds cold (built may be partly changed only for "supplies (reopening)").
---@param built table the last solved model, for old_scan
---@param old_scan BCE.Scan
---@param scan BCE.Scan the new scan
---@param overrides table<string, string>
---@param speeds table<string, number>
---@return boolean ok
---@return string why the outcome, for tests
function model.warm_build(built, old_scan, scan, overrides, speeds)
    local L = built and built.lp
    if (not L or not built.col_of or not old_scan) then
        return false, "no previous model"
    end
    if (L.status ~= "optimal") then
        return false, "previous model not optimal"
    end
    if (built.warm_chain >= WARM_MAX_CHAIN) then
        return false, "warm chain limit"
    end
    if (scan.surface_index ~= built.surface_index) then
        return false, "surface"
    end
    if (scan.tech_sig ~= built.tech_sig) then
        return false, "research, recipes or bonuses"
    end
    if (scan.lane_rate ~= built.lane) then
        return false, "belts"
    end
    if (scan.use_analyzer ~= built.use_analyzer) then
        return false, "analyzer setting"
    end
    for id, v in pairs(overrides) do
        if (built.overrides[id] ~= v) then
            return false, "unlimited items"
        end
    end
    for id, v in pairs(built.overrides) do
        if (overrides[id] ~= v) then
            return false, "unlimited items"
        end
    end

    local prep = model.prepare(scan, overrides, built.track_steam)
    local need = prep.need_sorted
    if (#need ~= #built.need_sorted) then
        return false, "item balances"
    end
    for i, id in ipairs(need) do
        if (built.need_sorted[i] ~= id) then
            return false, "item balances"
        end
    end
    local node_con = built.node_con
    -- supplies and "any" transfers: the same
    local n_sup = 0
    for id, _ in pairs(prep.supply_ids) do
        if (node_con[id]) then
            if (not built.supply_vars[id]) then
                return false, "supplies"
            end
            n_sup = n_sup + 1
        end
    end
    if (n_sup ~= table_size(built.supply_vars)) then
        return false, "supplies"
    end
    local tk = 0
    for _, id in ipairs(need) do
        for _, cid in ipairs(prep.nodes[id].children or {}) do
            if (node_con[cid]) then
                tk = tk + 1
                local tr = built.transfers[tk]
                if (not tr or tr.any ~= id or tr.child ~= cid) then
                    return false, "fluid temperatures"
                end
            end
        end
    end
    if (tk ~= #built.transfers) then
        return false, "fluid temperatures"
    end
    if (model.target_signature(scan, prep.kept) ~= built.target_sig) then
        return false, "targets"
    end

    -- match the groups
    local rows = scan.rows
    local have_of = have_counts(rows, prep.kept)
    local bounds = {} ---@type { j: integer, value: number? }[] bound changes
    local add = {} ---@type { col: table, cost: number, upper: number?, ri: integer, role: string }[]
    local row_var, twin_var, col_of = {}, {}, {}
    local used = {} ---@type table<string, true>
    local changed = 0
    local function bound(j, value)
        if (L.upper[j] ~= value) then
            bounds[#bounds + 1] = { j = j, value = value }
            return true
        end
        return false
    end
    for _, ri in ipairs(prep.kept) do
        local row = rows[ri]
        local kind, ub, cv, ct = row_spec(row, have_of[ri], speeds, built.lane)
        local col = row_column(row, node_con)
        local old = built.col_of[row.key]
        if (old) then
            used[row.key] = true
            if (not same_column(L.A[old.v], col) or (old.t and not same_column(L.A[old.t], col))) then
                return false, "what a group makes changed: " .. row.key
            end
            local c = L.c[1]
            if (kind == "target") then
                if (not old.t or not close(c[old.v], cv) or not close(c[old.t], ct)) then
                    return false, "target cost"
                end
                bound(old.v, ub)
                row_var[ri], twin_var[ri] = old.v, old.t
            elseif (old.t) then
                -- had a column for the buildings you have and one beyond them
                if (not close(c[old.t], ct or cv)) then
                    return false, "cost changed: " .. row.key
                end
                if (kind == "have" and not close(c[old.v], cv)) then
                    return false, "rent changed: " .. row.key
                end
                if (bound(old.v, kind == "have" and ub or 0)) then
                    changed = changed + 1
                end
                row_var[ri], twin_var[ri] = old.v, old.t
            else
                -- had none of them: one column at hassle
                if (not close(c[old.v], kind == "have" and ct or cv)) then
                    return false, "cost changed: " .. row.key
                end
                if (kind == "have") then
                    -- now you have some: a column for them, the old one goes beyond
                    add[#add + 1] = { col = col, cost = cv, upper = ub, ri = ri, role = "v" }
                    twin_var[ri] = old.v
                    changed = changed + 1
                else
                    row_var[ri] = old.v
                end
            end
        else
            -- a group the last model didn't have
            add[#add + 1] = { col = col, cost = cv, upper = ub, ri = ri, role = "v" }
            if (ct) then
                add[#add + 1] = { col = col, cost = ct, upper = nil, ri = ri, role = "t" }
            end
            changed = changed + 1
        end
    end
    -- groups that are gone: locked at 0
    local dead_now = 0
    for key, cols in pairs(built.col_of) do
        if (not used[key]) then
            changed = changed + 1
            bound(cols.v, 0)
            if (cols.t) then
                bound(cols.t, 0)
            end
        end
    end
    if (changed > math.max(WARM_MAX_CHANGED, WARM_MAX_CHANGED_SHARE * #prep.kept)) then
        return false, "too many changes (" .. changed .. ")"
    end
    -- columns in use after this: groups, transfers, supplies
    local live = #add + #built.transfers + n_sup
    for _, ri in ipairs(prep.kept) do
        live = live + (row_var[ri] and 1 or 0) + (twin_var[ri] and 1 or 0)
    end
    dead_now = (L.n + #add) - live
    if (dead_now > WARM_MAX_DEAD_SHARE * (L.n + #add)) then
        return false, "too many unused columns"
    end

    -- the checks passed: change the model. Supplies first, kept feasible (a capped supply at its
    -- cap would otherwise jump to the open bound)
    if (not model.uncap_supplies(built)) then
        return false, "supplies (reopening)"
    end
    local cols, costs = {}, {}
    for t, a in ipairs(add) do
        cols[t], costs[t] = a.col, a.cost
    end
    local ids = lp.extend(L, cols, costs)
    for t, a in ipairs(add) do
        local j = ids[t]
        if (a.role == "v") then
            row_var[a.ri] = j
        else
            twin_var[a.ri] = j
        end
        lp.set_bound(L, j, a.upper)
    end
    for _, b in ipairs(bounds) do
        lp.set_bound(L, b.j, b.value)
    end
    lp.commit_bounds(L)
    for _, ri in ipairs(prep.kept) do
        col_of[rows[ri].key] = { v = row_var[ri], t = twin_var[ri] }
    end

    built.kept = prep.kept
    built.row_var, built.twin_var, built.col_of = row_var, twin_var, col_of
    built.modes, built.defaults, built.nodes = prep.modes, prep.defaults, prep.nodes
    built.caps, built.capped = nil, nil
    -- projects: the candidates (and their locked columns) still hold if what they depend on is
    -- the same; otherwise they are looked for again (the old columns stay locked)
    if (built.cand_list and select(3, candidate_inputs(scan, prep.kept, prep.modes)) ~= built.cand_sig) then
        built.cand_list, built.cand_var, built.cand_sig = nil, nil, nil
    end
    built.warm = true
    built.warm_refresh = { work0 = L.work, changed = changed, added = #add, bounds = #bounds }
    built.warm_chain = built.warm_chain + 1
    return true, string.format("warm: %d groups changed, %d columns added, %d bounds%s", changed, #add, #bounds,
        built.cand_list and ", candidates kept" or "")
end

--- Production statistics of the last hour, per second: what came in from outside the model.
---@param id string node id
---@param force LuaForce
---@param surface LuaSurface
---@return number
local function made_last_hour(id, force, surface)
    local name = id:match("^item/([^(]+)")
    local stats
    if (name) then
        stats = force.get_item_production_statistics(surface)
    else
        name = id:match("^fluid/([^/]+)")
        stats = name and force.get_fluid_production_statistics(surface)
    end
    if (not stats) then
        return 0
    end
    local ok, made = pcall(stats.get_flow_count, { name = name, category = "input",
        precision_index = defines.flow_precision_index.one_hour, count = true })
    return (ok and made or 0) / 3600
end

--- Caps the supplies of items brought in, on a solved model: at what the factory made in the
--- last hour, or what the plan uses if that is more, so projects can't lean on free supply.
--- The solve then continues (lp.step). False when that isn't possible (build it again).
---@param built table
---@param force LuaForce
---@param surface LuaSurface
---@return boolean
function model.cap_supplies(built, force, surface)
    local L = built.lp
    built.caps = {}
    for id, v in pairs(built.supply_vars) do
        local cap = math.max(made_last_hour(id, force, surface), lp.value(L, v))
        if (not lp.set_upper(L, v, cap)) then
            return false
        end
        built.caps[id] = cap
    end
    built.capped = true
    return true
end

--- Opens the supplies again, before a solve continues from this one (lp.step): what the plan
--- uses changes with it. False when that isn't possible (build it again).
---@param built table
---@return boolean
function model.uncap_supplies(built)
    for _, v in pairs(built.supply_vars) do
        if (not lp.set_upper(built.lp, v, SUPPLY_OPEN)) then
            return false
        end
    end
    built.caps = nil
    built.capped = nil
    return true
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
---@field row_extra table<integer, number> scan row index -> buildings the plan adds beyond the ones you have
---@field price table<string, number> item -> hassle one more unit per second of it saves
---@field projects BCE.Projects? filled in once the projects are tested (model.whatif_finish)

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
    local row_x, row_have, main_of, row_extra = {}, {}, {}, {} ---@type table<integer, number>, table<integer, number>, table<integer, string>, table<integer, number>
    for _, ri in ipairs(built.kept) do
        local row = rows[ri]
        local x = lp.value(st, built.row_var[ri])
        if (built.twin_var[ri]) then
            local extra = lp.value(st, built.twin_var[ri])
            x = x + extra
            if (not row.is_target and extra > RUN_TOL) then
                row_extra[ri] = extra
            end
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
            if (modes[a.id] ~= nil and (nodes[a.id].node.type ~= "map-entity" or modes[a.id] == "counted")) then
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
    -- a supply (capped at what came in last hour) is what can be made of it
    for id, cap in pairs(built.caps or {}) do
        item(id).capacity = item(id).capacity + cap
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
        row_extra = row_extra,
        price = model.prices(built),
    }
end

-- ---------------------------------------------------------------------------
-- Projects
--
-- A project: a recipe you don't use for your targets yet, built fresh (no modules) in a type of
-- building you can build. Once the plan is solved (and shown), every unlocked recipe in every building
-- type that can make it is a candidate (spread over ticks). The plan prices every item in hassle;
-- at those prices the most promising candidates are screened (model.screen), added to the solved
-- model as locked columns (lp.extend), and each is tried alone on a copy of it: how much hassle it
-- saves at your speeds, net of its own buildings, and how the running cost changes.

--- Candidates tried as what-ifs. The top 10 by hassle saved were within the first 37 screened
--- on a large Py base (2026-11-25): screening by price misses part of what a project changes.
model.TEST_PROJECTS = 40
--- Projects shown.
model.SHOW_PROJECTS = 10
--- At most this many screened candidates make the same main product.
local PER_PRODUCT = 3
--- Production calculations per unit of solver work, while looking for candidates: about as long
--- as the solver takes (0.2 ms per calculation, 0.18 ms per 1000 work).
local CALLS_PER_WORK = 1 / 1250

---@class BCE.Candidate
---@field n integer its index in the list of candidates
---@field recipe LuaRecipePrototype
---@field entity LuaEntityPrototype
---@field quality LuaQualityPrototype
---@field amounts { id: string, node: Rates.Node, amount: number }[] per building
---@field hassle number hassle of one new building (building_cost)
---@field rent number running cost of one building per second

local function can_craft(entity, recipe)
    local cats = entity.crafting_categories or {}
    local ok = false
    for _, c in ipairs(recipe.categories or { recipe.category }) do
        if (cats[c]) then
            ok = true
            break
        end
    end
    if (not ok) then
        return false
    end
    local nf, ni = 0, 0
    for _, ing in ipairs(recipe.ingredients) do
        if (ing.type == "fluid") then
            nf = nf + 1
        else
            ni = ni + 1
        end
    end
    for _, p in ipairs(recipe.products) do
        if (p.type == "fluid") then
            nf = nf + 1
        end
    end
    if (nf > #entity.fluidbox_prototypes) then
        return false
    end
    local max = entity.ingredient_count
    return not (max and ni > max)
end

--- Whether the plan could feed it: every ingredient it needs is counted in the plan, or unlimited.
---@param amounts { id: string, node: Rates.Node, amount: number }[]
---@param built table
local function plan_can_feed(amounts, built)
    for _, am in ipairs(amounts) do
        if (am.amount < 0 and not built.node_con[am.id]) then
            if (built.modes[am.id] ~= "ignored" and not is_ignored_node(am.node, built.track_steam)) then
                return false
            end
        end
    end
    return true
end

--- Starts the search for candidates: what to try, nothing tried yet.
---@param scan BCE.Scan
---@param built table
---@param force LuaForce
---@param surface LuaSurface
local function candidates_start(scan, built, force, surface)
    local entities, used, sig = candidate_inputs(scan, built.kept, built.modes)
    local seen = {}
    for _, e in ipairs(entities) do
        seen[e.entity.name] = true
    end
    local normal = prototypes.quality["normal"]
    local recipes = {}
    for name, r in pairs(force.recipes) do
        local proto = prototypes.recipe[name]
        if (r.enabled and proto and not proto.hidden) then
            if (not used[name]) then
                recipes[#recipes + 1] = proto
            end
            -- every building type you can build, by an unlocked recipe for the item that places it
            -- (research and recipe changes start a Refresh cold, so the kept candidates never miss one)
            for _, p in ipairs(proto.products or {}) do
                local item = p.type == "item" and prototypes.item[p.name]
                local e = item and not item.hidden and item.place_result
                if (e and crafter_types[e.type] and not e.fixed_recipe and not e.hidden and not seen[e.name]) then
                    seen[e.name] = true
                    entities[#entities + 1] = { entity = e, quality = normal }
                end
            end
        end
    end
    table.sort(recipes, function(a, b) return a.name < b.name end)
    table.sort(entities, function(a, b) return a.entity.name < b.entity.name end)
    return { force = force, surface = surface, lane = scan.lane_rate, entities = entities, recipes = recipes, ri = 1, ei = 1,
        list = {}, sig = sig }
end

--- Tries recipe × building pairs until about `budget` production calculations are done.
---@return boolean finished
local function candidates_step(cjob, built, budget)
    local entities, recipes = cjob.entities, cjob.recipes
    local left = budget
    while (cjob.ri <= #recipes) do
        if (left <= 0) then
            return false
        end
        local proto = recipes[cjob.ri]
        local e = entities[cjob.ei]
        if (e and can_craft(e.entity, proto)) then
            left = left - 1
            local cconf = { type = "crafting-machine", entity = e.entity, quality = e.quality,
                module_effects = {}, recipe = proto, recipe_quality = e.quality }
            local ok, raw = pcall(api.configuration.get_production, cconf,
                { force = cjob.force, surface = cjob.surface, use_pollution = false })
            if (ok and raw) then
                raw = farm_amounts(cconf, raw)
                local summed = sum_amounts(raw)
                if (plan_can_feed(summed, built)) then
                    cjob.list[#cjob.list + 1] = { n = #cjob.list + 1, recipe = proto, entity = e.entity, quality = e.quality, amounts = summed,
                        hassle = building_cost({ conf = cconf, amounts = summed }, cjob.lane), rent = running_cost(raw) }
                end
            end
        else
            left = left - 0.02
        end
        cjob.ei = cjob.ei + 1
        if (cjob.ei > #entities) then
            cjob.ei = 1
            cjob.ri = cjob.ri + 1
        end
    end
    return true
end

--- What one more unit per second of each item saves in the solved plan, in hassle.
---@param built table
---@return table<string, number>
function model.prices(built)
    local L = built.lp
    local price = {}
    for id, i in pairs(built.node_con) do
        local j = L.n + i
        price[id] = L.pos[j] and 0 or (L.d[1][j] / W_OVER)
    end
    return price
end

--- The candidates worth trying, most promising first: what they make minus what they use at the
--- plan's prices, minus their own hassle. The best building type per recipe, and only a few per
--- main product, so one cheap item doesn't take every place.
---@param built table solved
---@param cands BCE.Candidate[]
---@return BCE.Candidate[]
function model.screen(built, cands)
    local price = model.prices(built)
    local list = {}
    for ci, c in ipairs(cands) do
        local v, main, best = 0, nil, -1
        for _, am in ipairs(c.amounts) do
            local p = price[am.id]
            if (p) then
                v = v + am.amount * p
                if (am.amount > 0 and am.amount * p > best) then
                    main, best = am.id, am.amount * p
                end
            end
        end
        local score = v - c.hassle
        if (score > 1e-6) then
            list[#list + 1] = { ci = ci, score = score, main = main or "?" }
        end
    end
    table.sort(list, function(a, b)
        if (a.score ~= b.score) then return a.score > b.score end
        return a.ci < b.ci
    end)
    local pool, per, seen = {}, {}, {}
    for _, e in ipairs(list) do
        if (#pool >= model.TEST_PROJECTS) then
            break
        end
        local c = cands[e.ci]
        if (not seen[c.recipe.name] and (per[e.main] or 0) < PER_PRODUCT) then
            seen[c.recipe.name] = true
            per[e.main] = (per[e.main] or 0) + 1
            pool[#pool + 1] = c
        end
    end
    return pool
end

--- The objective of a solved state, in hassle (with the rent tiebreak in it).
local function objective(L)
    local c, total = L.c[1], 0
    for j = 1, L.n do
        local v = lp.value(L, j)
        if (v ~= 0 and c[j] ~= 0) then
            total = total + c[j] * v
        end
    end
    return total / W_OVER
end

--- Starts looking for projects on the solved (and capped) model: candidates first, unless the
--- model has them from an earlier run (they don't depend on the speeds).
---@param built table
---@param scan BCE.Scan
---@param force LuaForce
---@param surface LuaSurface
function model.whatif_start(built, scan, force, surface)
    local job = { phase = "cands", k = 1, tests = {}, results = {} }
    if (not built.cand_list) then
        job.cjob = candidates_start(scan, built, force, surface)
    end
    return job
end

--- 0..1 through the search for candidates, or nil once it is done.
function model.candidates_progress(job)
    if (job.phase ~= "cands" or not job.cjob) then
        return nil
    end
    return (job.cjob.ri - 1) / math.max(1, #job.cjob.recipes)
end

--- The screened candidates as columns of the solved model (each once), and its state to compare with.
local function whatif_prepare(job, built, scan)
    local rows, L = scan.rows, built.lp
    local pool = model.screen(built, built.cand_list)
    built.cand_var = built.cand_var or {}
    local cols, costs, added = {}, {}, {}
    for _, c in ipairs(pool) do
        if (not built.cand_var[c.n]) then
            local col = {}
            for _, am in ipairs(c.amounts) do
                local i = built.node_con[am.id]
                if (i) then
                    -- balance rows are "made − used ≥ 0", stored negated (model.build)
                    col[i] = (col[i] or 0) - am.amount
                end
            end
            cols[#cols + 1] = col
            costs[#costs + 1] = W_OVER * c.hassle + W_RENT * math.max(c.rent, MIN_RENT)
            added[#added + 1] = c
        end
    end
    for t, j in ipairs(lp.extend(L, cols, costs)) do
        built.cand_var[added[t].n] = j
    end
    for _, c in ipairs(pool) do
        job.tests[#job.tests + 1] = { cand = c, var = built.cand_var[c.n] }
    end
    local base_twin, base_run = {}, {}
    for _, ri in ipairs(built.kept) do
        if (not rows[ri].is_target) then
            local tv = built.twin_var[ri]
            local t = tv and lp.value(L, tv) or 0
            base_twin[ri] = t
            base_run[ri] = lp.value(L, built.row_var[ri]) + t
        end
    end
    job.base_twin, job.base_run, job.obj0 = base_twin, base_run, objective(L)
    job.phase = "test"
end

--- Reads a finished what-if.
local function whatif_read(job, built, scan, fork, test)
    local rows = scan.rows
    local diff, drent = {}, 0
    for ri, t0 in pairs(job.base_twin) do
        local tv = built.twin_var[ri]
        local t = tv and lp.value(fork, tv) or 0
        local run = lp.value(fork, built.row_var[ri]) + t
        drent = drent + (run - job.base_run[ri]) * rows[ri].rent
        if (math.abs(t - t0) > 1e-6) then
            diff[ri] = t - t0
        end
    end
    local x = lp.value(fork, test.var)
    drent = drent + x * test.cand.rent
    -- the objective also holds the rent tiebreak: take it out, so saved is hassle alone
    local saved = job.obj0 - objective(fork) + drent * W_RENT / W_OVER
    job.results[#job.results + 1] = { cand = test.cand, saved = saved, x = x, drent = drent, diff = diff }
end

--- Looks for projects and tries them, until about `budget` units of solver work are done.
---@return boolean finished
function model.whatif_step(job, built, scan, budget)
    if (job.phase == "cands") then
        if (job.cjob) then
            if (not candidates_step(job.cjob, built, math.max(1, budget * CALLS_PER_WORK))) then
                return false
            end
            built.cand_list, built.cand_sig = job.cjob.list, job.cjob.sig
            job.cjob = nil
        end
        -- the columns and a pass over the plan: about as long as a tick of the solver
        whatif_prepare(job, built, scan)
        return false
    end
    local spent = 0
    while (spent < budget) do
        if (not job.fork) then
            local test = job.tests[job.k]
            if (not test) then
                job.phase = "done"
                return true
            end
            local fork = lp.fork(built.lp)
            spent = spent + fork.N
            if (lp.set_upper(fork, test.var, 1e6)) then
                job.fork = fork
            else
                job.k = job.k + 1
            end
        else
            local fork = job.fork
            local w0 = fork.work
            local finished = lp.step(fork, budget - spent, true)
            spent = spent + (fork.work - w0)
            if (finished) then
                if (fork.status == "optimal") then
                    whatif_read(job, built, scan, fork, job.tests[job.k])
                end
                job.fork = nil
                job.k = job.k + 1
            end
        end
    end
    return false
end

---@class BCE.Project
---@field recipe LuaRecipePrototype
---@field entity LuaEntityPrototype
---@field x number buildings to build
---@field saved number hassle saved at your speeds, net of its own buildings
---@field drent number change in running cost per second (negative: saved)
---@field diff table<integer, number> scan row index -> change in the buildings the plan adds there
---@field downs { ri: integer, d: number }[] rows that need fewer new buildings, most first
---@field ups { ri: integer, d: number }[] rows that need more new buildings, most first

---@class BCE.Projects
---@field tested integer
---@field extra_buildings number new buildings the plan adds in groups you have
---@field extra_hassle number their hassle
---@field list BCE.Project[] best first, at most model.SHOW_PROJECTS

--- The tried projects, best first.
---@param job table finished
---@param built table
---@param scan BCE.Scan
---@param result BCE.Result
---@return BCE.Projects
function model.whatif_finish(job, built, scan, result)
    table.sort(job.results, function(a, b) return a.saved > b.saved end)
    local list = {}
    for _, r in ipairs(job.results) do
        if (#list >= model.SHOW_PROJECTS or r.saved <= 1e-6) then
            break
        end
        local downs, ups = {}, {}
        for ri, d in pairs(r.diff) do
            if (d < -0.1) then
                downs[#downs + 1] = { ri = ri, d = d }
            elseif (d > 0.1) then
                ups[#ups + 1] = { ri = ri, d = d }
            end
        end
        table.sort(downs, function(a, b) return a.d < b.d end)
        table.sort(ups, function(a, b) return a.d > b.d end)
        local c = r.cand
        list[#list + 1] = { recipe = c.recipe, entity = c.entity, quality = c.quality, x = r.x, saved = r.saved, drent = r.drent,
            diff = r.diff, downs = downs, ups = ups }
    end
    local n, h = 0, 0
    for ri, x in pairs(result.row_extra) do
        if (x > 1e-3) then
            n = n + x
            h = h + x * model.clone_hassle(scan.rows[ri], scan.lane_rate)
        end
    end
    return { tested = #job.results, extra_buildings = n, extra_hassle = h, list = list }
end

--- Regret: a shown project that would make at least 1 and 20% of these new buildings
--- unnecessary. The one that cuts them the most.
---@param projects BCE.Projects
---@param ris integer[] scan rows
---@param row_extra table<integer, number>
---@return BCE.Project? project
---@return number? left what is left of them with it
---@return integer? rank
function model.regret(projects, ris, row_extra)
    local xb = 0
    for _, ri in ipairs(ris) do
        xb = xb + (row_extra[ri] or 0)
    end
    if (xb < 1) then
        return nil
    end
    local best, left, rank = nil, xb, nil
    for k, p in ipairs(projects.list) do
        local x2 = 0
        for _, ri in ipairs(ris) do
            x2 = x2 + (row_extra[ri] or 0) + (p.diff[ri] or 0)
        end
        if (x2 < left - 1e-6 and xb - x2 >= math.max(1, 0.2 * xb)) then
            best, left, rank = p, x2, k
        end
    end
    return best, left, rank
end

--- The rows whose new buildings are for an item: the plan's extra buildings making it.
---@param result BCE.Result
---@param id string
---@return integer[]
function model.extra_rows_of(result, id)
    local list = {}
    for ri, x in pairs(result.row_extra) do
        if (x > 1e-3 and result.main_of[ri] == id) then
            list[#list + 1] = ri
        end
    end
    return list
end

return model
