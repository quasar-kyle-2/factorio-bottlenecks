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
--- (byproducts it makes too much of come free).
---
--- Each cost is a sum over other costs, so they make a set of linear equations. They're solved
--- exactly, a loop at a time: the items that feed each other (directly or around a loop) are
--- found first, then solved in order, each loop as one system once what feeds it is known (in
--- Py most of a base is one loop of hundreds of items, through barrels, ash and the like). A loop that makes more than it uses up has no answer: its costs grow without end.
--- Those get a fixed number of rounds instead, and the report says the numbers are rough.
---
--- It runs as a job, a little each tick (a big base takes about a second in one go). The job is
--- plain data, so it can sit in storage: start it, then step it until it says it's done.

--- Work units a step gets per tick. A big Py base takes about 170k for a report, about 0.15 s in
--- one go on a fast PC: 2500 a tick spreads that over about a second, at roughly half the frame
--- rate while it runs.
detail.PROD_WORK_PER_TICK = 2500
--- Work units one group's module check counts for.
local PROD_INFO_WORK = 40
--- Rounds a loop with no answer gets.
local MAX_PASSES = 200

---@class BCE.ProdExpr a + sum of f[k] * cost[v[k]]
---@field a number
---@field v string[]
---@field f number[]
---@field at table<string, integer> where each node is in v

---@class BCE.ProdSolve one loop being solved
---@field m string[] its nodes
---@field eqs table<string, { a: number, t: table<string, number> }> each node's equation, among the loop's nodes
---@field users table<string, table<string, true>> the equations each node is in
---@field nt table<string, integer> terms in each equation
---@field nu table<string, integer> equations each node is in, not counting its own
---@field done table<string, true>
---@field order string[] the nodes solved for, in order
---@field hs number[] heap: scores
---@field hn string[] heap: nodes

---@class BCE.ProdJob
---@field id string
---@field scan BCE.Scan
---@field result BCE.Result
---@field force LuaForce
---@field phase "flows" | "charge" | "equations" | "order" | "solve" | "draw" | "modules" | "done"
---@field i integer
---@field work integer units done so far
---@field counted table<string, true>
---@field made table<string, number>
---@field used table<string, number>
---@field running integer[]
---@field any_children table<string, string[]>
---@field charge table<integer, { id: string, w: number }[]>
---@field vars string[] the nodes with a cost to work out, in the order they came up
---@field eq table<string, BCE.ProdExpr> each one's cost, from the others
---@field rexpr table<integer, BCE.ProdExpr> each running building's draw, from the costs
---@field ord table? the loop finder's state
---@field sccs string[][] the loops (and single nodes), each after the ones it uses
---@field sol BCE.ProdSolve?
---@field cost table<string, number>
---@field draw table<integer, number>
---@field pull integer[] rows that pull on the item
---@field modules LuaItemPrototype[]? unlocked productivity modules
---@field list BCE.ProdRow[] the answer, best use of a module first
---@field pulling integer groups that pull on it at all
---@field settled boolean false: a loop makes more than it uses up, so its costs are rough

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
        vars = {}, eq = {}, rexpr = {}, sccs = {}, cost = { [id] = 1 }, draw = {}, pull = {}, list = {},
        pulling = 0, settled = true }
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
        local eq = job.eq
        for _, c in ipairs(list) do
            c.w = c.w / total
            if (not eq[c.id]) then
                eq[c.id] = { a = 0, v = {}, f = {}, at = {} }
                job.vars[#job.vars + 1] = c.id
            end
        end
        job.charge[ri] = list
    end
    return #row.amounts + 1
end

---@param e BCE.ProdExpr
---@param v string
---@param f number
local function expr_add(e, v, f)
    local k = e.at[v]
    if (k) then
        e.f[k] = e.f[k] + f
    else
        k = #e.v + 1
        e.v[k], e.f[k], e.at[v] = v, f, k
    end
end

--- Step 3: a running building's draw as a sum over costs, added to the costs of the products
--- it's charged to.
---@param job BCE.ProdJob
local function step_equations(job, ri)
    local row, x = job.scan.rows[ri], job.result.row_x[ri]
    local eq, id = job.eq, job.id
    local r = { a = 0, v = {}, f = {}, at = {} }
    for _, a in ipairs(row.amounts) do
        if (a.amount < 0) then
            local rate = -a.amount * x
            local children = job.any_children[a.id]
            if (a.id == id) then
                r.a = r.a + rate
            elseif (eq[a.id]) then
                expr_add(r, a.id, rate)
            elseif (children) then
                -- a fluid at any temperature: its temperatures, by how much of each the plan makes
                local w = 0
                for _, cid in ipairs(children) do
                    w = w + (job.made[cid] or 0)
                end
                if (w > 0) then
                    for _, cid in ipairs(children) do
                        local m = job.made[cid] or 0
                        if (m > 0 and cid == id) then
                            r.a = r.a + rate * m / w
                        elseif (m > 0 and eq[cid]) then
                            expr_add(r, cid, rate * m / w)
                        end
                    end
                end
            end
        end
    end
    job.rexpr[ri] = r
    local charge = job.charge[ri] or {}
    for _, c in ipairs(charge) do
        local e, s = eq[c.id], c.w / job.used[c.id]
        e.a = e.a + r.a * s
        for k, v in ipairs(r.v) do
            expr_add(e, v, r.f[k] * s)
        end
    end
    return #row.amounts + 1 + #charge * (#r.v + 1)
end

---@param o table
---@param v string
local function ord_visit(o, v)
    o.n = o.n + 1
    o.index[v], o.low[v] = o.n, o.n
    o.stack[#o.stack + 1], o.on[v] = v, true
    o.cs[#o.cs + 1], o.ep[v] = v, 1
end

--- Step 4: the loops, by Tarjan's algorithm: a node's equation uses the nodes in it, and a loop
--- is a set of nodes that all use each other. One move at a time, so it can stop anywhere. The
--- loops come out each after the ones it uses.
---@param job BCE.ProdJob
---@return boolean done
local function step_order(job)
    local o = job.ord
    if (not o) then
        o = { index = {}, low = {}, on = {}, stack = {}, cs = {}, ep = {}, n = 0, vi = 1 }
        job.ord = o
    end
    local eq, cs = job.eq, o.cs
    if (#cs == 0) then
        local vars = job.vars
        while (o.vi <= #vars and o.index[vars[o.vi]]) do
            o.vi = o.vi + 1
        end
        if (o.vi > #vars) then
            job.ord = nil
            return true
        end
        ord_visit(o, vars[o.vi])
        return false
    end
    local v = cs[#cs]
    local e = eq[v]
    local k = o.ep[v]
    if (k <= #e.v) then
        o.ep[v] = k + 1
        local w = e.v[k]
        if (not o.index[w]) then
            ord_visit(o, w)
        elseif (o.on[w] and o.index[w] < o.low[v]) then
            o.low[v] = o.index[w]
        end
        return false
    end
    cs[#cs] = nil
    if (o.low[v] == o.index[v]) then
        local scc = {}
        repeat
            local w = o.stack[#o.stack]
            o.stack[#o.stack], o.on[w] = nil, nil
            scc[#scc + 1] = w
        until (w == v)
        job.sccs[#job.sccs + 1] = scc
    end
    local u = cs[#cs]
    if (u and o.low[v] < o.low[u]) then
        o.low[u] = o.low[v]
    end
    return false
end

--- A loop with no answer: a fixed number of rounds from zero, as if it were settling.
---@param job BCE.ProdJob
---@param m string[]
---@return integer work
local function solve_rough(job, m)
    local eq, cost = job.eq, job.cost
    local inside = {}
    for _, n in ipairs(m) do
        inside[n] = true
        cost[n] = 0
    end
    local work = 0
    for _ = 1, MAX_PASSES do
        local new = {}
        for _, n in ipairs(m) do
            local e = eq[n]
            local s = e.a
            for k, v in ipairs(e.v) do
                s = s + e.f[k] * (cost[v] or 0)
            end
            new[n] = s
            work = work + #e.v + 1
        end
        for n, s in pairs(new) do
            cost[n] = s
        end
    end
    job.settled = false
    return work
end

--- A min-heap of (score, node) in two arrays. A node is pushed again when its score changes;
--- the old entries are skipped when they come up.
---@param sol BCE.ProdSolve
---@param score number
---@param n string
local function heap_push(sol, score, n)
    local hs, hn = sol.hs, sol.hn
    local i = #hs + 1
    while (i > 1) do
        local up = math.floor(i / 2)
        if (hs[up] <= score) then
            break
        end
        hs[i], hn[i] = hs[up], hn[up]
        i = up
    end
    hs[i], hn[i] = score, n
end

---@param sol BCE.ProdSolve
---@return number score
---@return string n
local function heap_pop(sol)
    local hs, hn = sol.hs, sol.hn
    local score, n = hs[1], hn[1]
    local size = #hs
    local ls, ln = hs[size], hn[size]
    hs[size], hn[size] = nil, nil
    size = size - 1
    if (size > 0) then
        local i = 1
        while (true) do
            local c = 2 * i
            if (c > size) then
                break
            end
            if (c < size and hs[c + 1] < hs[c]) then
                c = c + 1
            end
            if (hs[c] >= ls) then
                break
            end
            hs[i], hn[i] = hs[c], hn[c]
            i = c
        end
        hs[i], hn[i] = ls, ln
    end
    return score, n
end

--- Step 5, a piece at a time: the costs of the next loop (or single node), once the ones it uses
--- are known. A loop is solved by substitution, one node per call: take a node's equation, solve
--- it for that node, and put it into every equation that uses it. The node that adds the least
--- goes first (fewest users times fewest terms), which keeps a big loop sparse. The costs then
--- come out backwards. A loop has an answer only when every node solves with a positive divisor.
---@param job BCE.ProdJob
---@return integer work
local function step_solve(job)
    local eq, cost = job.eq, job.cost
    local sol = job.sol
    if (not sol) then
        local m = job.sccs[job.i]
        if (#m == 1 and not eq[m[1]].at[m[1]]) then
            local e = eq[m[1]]
            local s = e.a
            for k, v in ipairs(e.v) do
                s = s + e.f[k] * (cost[v] or 0)
            end
            cost[m[1]] = s
            job.i = job.i + 1
            return #e.v + 1
        end
        -- the loop's equations among its own nodes, with what feeds it already in
        local inside = {}
        for _, n in ipairs(m) do
            inside[n] = true
        end
        local eqs, users, nt, nu, work = {}, {}, {}, {}, 0
        for _, n in ipairs(m) do
            users[n], nu[n] = {}, 0
        end
        for _, n in ipairs(m) do
            local e = eq[n]
            local t, c, s = {}, 0, e.a
            for k, v in ipairs(e.v) do
                if (inside[v]) then
                    t[v] = e.f[k]
                    c = c + 1
                    if (v ~= n) then
                        users[v][n] = true
                        nu[v] = nu[v] + 1
                    end
                else
                    s = s + e.f[k] * (cost[v] or 0)
                end
            end
            eqs[n], nt[n] = { a = s, t = t }, c
            work = work + #e.v + 1
        end
        sol = { m = m, eqs = eqs, users = users, nt = nt, nu = nu, done = {}, order = {}, hs = {}, hn = {} }
        for _, n in ipairs(m) do
            heap_push(sol, nu[n] * nt[n], n)
        end
        job.sol = sol
        return work + #m
    end
    local m, eqs, users, nt, nu, done = sol.m, sol.eqs, sol.users, sol.nt, sol.nu, sol.done
    if (#sol.order < #m) then
        -- the node that adds the least
        local p, work = nil, 0
        repeat
            local score, n = heap_pop(sol)
            work = work + 1
            if (not done[n] and score == nu[n] * nt[n]) then
                p = n
            end
        until (p)
        local e = eqs[p]
        local d = 1 - (e.t[p] or 0)
        if (d < 1e-12) then
            job.sol = nil
            job.i = job.i + 1
            return #m + solve_rough(job, m)
        end
        if (e.t[p]) then
            e.t[p] = nil
            nt[p] = nt[p] - 1
        end
        e.a = e.a / d
        local changed = {}
        for v, f in pairs(e.t) do
            e.t[v] = f / d
            users[v][p] = nil
            nu[v] = nu[v] - 1
            changed[v] = true
        end
        for n in pairs(users[p]) do
            changed[n] = true
            local en = eqs[n]
            local g = en.t[p]
            en.t[p] = nil
            nt[n] = nt[n] - 1
            en.a = en.a + g * e.a
            for v, f in pairs(e.t) do
                local old = en.t[v]
                if (old) then
                    en.t[v] = old + g * f
                else
                    en.t[v] = g * f
                    nt[n] = nt[n] + 1
                    if (v ~= n) then
                        users[v][n] = true
                        nu[v] = nu[v] + 1
                        changed[v] = true
                    end
                end
            end
            work = work + nt[p] + 1
        end
        users[p], done[p] = nil, true
        sol.order[#sol.order + 1] = p
        for n in pairs(changed) do
            heap_push(sol, nu[n] * nt[n], n)
            work = work + 1
        end
        return work
    end
    -- the costs, backwards: each node's equation only has nodes solved after it
    local x, order = {}, sol.order
    for k = #order, 1, -1 do
        local p = order[k]
        local e = eqs[p]
        local s = e.a
        for v, f in pairs(e.t) do
            s = s + f * x[v]
        end
        if (s ~= s or s == math.huge or s < -1e-9 * math.max(1, math.abs(s))) then
            job.sol = nil
            job.i = job.i + 1
            return #m + solve_rough(job, m)
        end
        x[p] = s
    end
    for _, n in ipairs(m) do
        cost[n] = math.max(0, x[n])
    end
    job.sol = nil
    job.i = job.i + 1
    return #m * 2
end

--- Step 6: each running building's draw, from the costs.
---@param job BCE.ProdJob
local function step_draw(job, ri)
    local r, cost = job.rexpr[ri], job.cost
    local s = r.a
    for k, v in ipairs(r.v) do
        s = s + r.f[k] * (cost[v] or 0)
    end
    job.draw[ri] = s
    return #r.v + 1
end

--- Step 7: a group that pulls on the item, if it takes a productivity module.
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
                job.phase, job.i = "equations", 1
            else
                used = step_charge(job, job.running[job.i])
                job.i = job.i + 1
            end
        elseif (job.phase == "equations") then
            if (job.i > #job.running) then
                job.phase, job.i = "order", 1
            else
                used = step_equations(job, job.running[job.i])
                job.i = job.i + 1
            end
        elseif (job.phase == "order") then
            if (step_order(job)) then
                job.phase, job.i = "solve", 1
            end
        elseif (job.phase == "solve") then
            if (job.i > #job.sccs) then
                job.phase, job.i = "draw", 1
            else
                used = step_solve(job)
            end
        elseif (job.phase == "draw") then
            if (job.i > #job.running) then
                for _, ri in ipairs(job.running) do
                    if (job.draw[ri] > 1e-9) then
                        job.pull[#job.pull + 1] = ri
                    end
                end
                job.pulling = #job.pull
                job.modules = unlocked_prod_modules(job.force)
                job.phase, job.i = "modules", 1
            else
                used = step_draw(job, job.running[job.i])
                job.i = job.i + 1
            end
        elseif (job.phase == "modules") then
            if (job.i > #job.pull) then
                table.sort(job.list, function(a, b)
                    if (a.per_module ~= b.per_module) then return a.per_module > b.per_module end
                    return a.ri < b.ri
                end)
                -- the working tables aren't needed any more
                job.made, job.used, job.charge, job.cost, job.any_children = nil, nil, nil, nil, nil
                job.vars, job.eq, job.rexpr, job.sccs = nil, nil, nil, nil
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
