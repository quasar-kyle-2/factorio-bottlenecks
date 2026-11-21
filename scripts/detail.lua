-- Item report: where an item goes and where it comes from, from the last answer and from what
-- the buildings are doing right now.

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

return detail
