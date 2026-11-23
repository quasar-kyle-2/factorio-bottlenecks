local gui = require("scripts.gui")
local model = require("scripts.model")
local detail = require("scripts.detail")
local lp = require("scripts.lp")
local handler = require("__core__.lualib.event_handler")
local flib_gui = require("__flib__.gui")
local entity_tracker = require("__sw-entity-tracker__.interface")

local TOOL = "bottleneck-calc-extreme-tool"

handler.add_libraries({
    flib_gui,
    gui,
})

---@param player LuaPlayer
local function setting(player, name)
    return settings.get_player_settings(player)["bottleneck-calc-extreme-" .. name].value
end

---@param built table
---@return LocalisedString
local function progress_caption(built)
    -- Iterations needed, measured on a large Py base (2026-11-19): 2.5-3.7 per item constraint
    -- from scratch, 0.2-1.3 when continuing after a speed change. Linear up to 90% of the
    -- estimate, then easing towards 99% so it keeps moving when the solve runs long.
    local estimate = math.max(1, (built.warm and 0.8 or 3.2) * built.n_constraints)
    local r = built.lp.iterations / estimate
    local pct = r < 0.9 and 100 * r or 90 + 9 * (1 - math.exp(-(r - 0.9) / 0.5))
    return { "gui.bottleneck-calc-extreme-solving", tostring(math.floor(pct)) }
end

--- Build the model from the last scan and start solving it over the next ticks.
---@param player LuaPlayer
local function start_solve(player)
    local s = gui.get_storage(player)
    if (not s.scan) then
        return
    end
    s.stopped = nil
    local built = model.build(s.scan, s.overrides, setting(player, "track-steam") --[[@as boolean]], s.speeds)
    s.built = built
    s.solved = nil
    s.result = nil
    if (built.n_targets == 0) then
        s.built = nil
        gui.show_progress(player, { "gui.bottleneck-calc-extreme-no-targets" })
        return
    end
    gui.show_progress(player, progress_caption(built))
end

---@param player LuaPlayer
local function run_scan(player)
    local s = gui.get_storage(player)
    s.stopped = nil
    local surface = s.surface_index and game.get_surface(s.surface_index)
    if (not surface) then
        return
    end

    local target_ids = {} ---@type table<integer, true>
    local any = false
    for unit_number, entity in pairs(s.targets) do
        if (entity.valid) then
            target_ids[entity.unit_number] = true
            any = true
        else
            s.targets[unit_number] = nil
        end
    end
    if (not any) then
        -- clean slate: an empty window, ready for "add consumers"
        s.scan, s.built, s.solved, s.result, s.scanned_targets = nil, nil, nil, nil, nil
        gui.show_progress(player, { "gui.bottleneck-calc-extreme-empty" })
        return
    end

    s.scan = model.scan(surface, player.force --[[@as LuaForce]], target_ids,
        setting(player, "use-analyzer") --[[@as boolean]])
    -- with the entities, so Undo can put back removed ones
    local scanned = {} ---@type table<integer, LuaEntity>
    for id in pairs(target_ids) do
        scanned[id] = s.targets[id]
    end
    s.scanned_targets = scanned
    start_solve(player)
end

gui.callbacks.rescan = run_scan

--- Whether the last scan had targets. Then target changes wait for Apply, so several can be
--- made before the (slow) scan and analysis; on a clean slate they start it right away.
---@param s BCE.PlayerStorage
local function has_applied_targets(s)
    return s.scan ~= nil and s.scanned_targets ~= nil and next(s.scanned_targets) ~= nil
end

local show_window ---@type fun(player: LuaPlayer)

--- Targets changed: wait for Apply when there were targets before, otherwise scan now.
---@param player LuaPlayer
local function targets_changed(player)
    if (has_applied_targets(gui.get_storage(player))) then
        show_window(player)
    else
        run_scan(player)
    end
end

gui.callbacks.remove_targets = function(player, unit_numbers)
    local s = gui.get_storage(player)
    for _, unit_number in ipairs(unit_numbers) do
        s.targets[unit_number] = nil
    end
    targets_changed(player)
end

--- A removed target group clicked again: back in, still waiting for Apply.
gui.callbacks.restore_targets = function(player, entities)
    local s = gui.get_storage(player)
    for _, entity in ipairs(entities) do
        if (entity.valid and entity.unit_number) then
            s.targets[entity.unit_number] = entity
        end
    end
    targets_changed(player)
end

--- Apply with target changes: the new speeds, then scan the new targets and work them out.
gui.callbacks.apply = function(player, speeds)
    local s = gui.get_storage(player)
    for row_key, speed in pairs(speeds) do
        s.speeds[row_key] = (math.abs(speed - 1) > 1e-9) and speed or nil
    end
    run_scan(player)
end

--- Target groups' speeds changed (Apply): continue from the last answer when possible, which
--- only a finished one is. After a cancel there is none, so it starts over. (The targets are
--- read-only while solving, so this never runs during one.)
gui.callbacks.set_speeds = function(player, changes)
    local s = gui.get_storage(player)
    local built = (not s.built) and s.solved or nil
    local warm = built ~= nil and s.scan ~= nil
    for row_key, speed in pairs(changes) do
        s.speeds[row_key] = (math.abs(speed - 1) > 1e-9) and speed or nil
        -- once one can't continue, the rest needn't try: start_solve builds from scratch
        warm = warm and model.set_speed(built, s.scan, row_key, speed)
    end
    if (warm) then
        built.warm = true
        s.stopped = nil
        s.built = built
        s.solved = nil
        gui.update_progress(player, progress_caption(built))
    else
        start_solve(player)
    end
end

gui.callbacks.add_consumers = function(player, type, name)
    local s = gui.get_storage(player)
    if (s.built) then
        return
    end
    local surface = s.surface_index and game.get_surface(s.surface_index)
    if (not surface) then
        return
    end
    -- Every building on the surface that uses it, whatever the targets or the last results are:
    -- the same every time. Ones that don't matter can be clicked off before Apply.
    if (not s.scan) then
        s.scan = model.scan(surface, player.force --[[@as LuaForce]], {}, setting(player, "use-analyzer") --[[@as boolean]])
    end
    local found, added = 0, 0
    for _, row in ipairs(s.scan.rows) do
        for _, a in ipairs(row.amounts) do
            if (a.amount < 0 and detail.node_is(a.node, type, name)) then
                -- the scan keeps entity references: game.get_entity_by_unit_number only
                -- finds a few entity types, not assemblers
                for _, entity in ipairs(row.entities or {}) do
                    if (entity.valid and entity.unit_number) then
                        found = found + 1
                        if (not s.targets[entity.unit_number]) then
                            s.targets[entity.unit_number] = entity
                            added = added + 1
                        end
                    end
                end
                break
            end
        end
    end
    if (found == 0) then
        player.print({ "gui.bottleneck-calc-extreme-no-consumers", "[" .. type .. "=" .. name .. "]" })
        return
    end
    if (added == 0) then
        return -- all of them are targets already
    end
    targets_changed(player)
end

--- The stop button: drop the solve in progress (and its lag). The last results go too, since
--- they no longer match the targets or speeds; the targets, speeds and unlimited items stay, and
--- Refresh starts again. Remembered, so opening the window again does not restart it either.
gui.callbacks.stop = function(player)
    local s = gui.get_storage(player)
    if (not s.built) then
        return
    end
    -- pending speeds stay: the targets still show, with their Apply button
    s.built, s.solved, s.result = nil, nil, nil
    s.stopped = true
    gui.show_progress(player, { "gui.bottleneck-calc-extreme-stopped" })
end

gui.callbacks.reset = function(player)
    local s = gui.get_storage(player)
    s.overrides = {}
    s.speeds = {}
    s.pending_speeds = nil
    s.targets = {}
    run_scan(player)
end

--- Item icon click: treat the item as unlimited (don't trace where it comes from), or count it again.
gui.callbacks.toggle_item = function(player, node_id)
    local s = gui.get_storage(player)
    s.overrides[node_id] = (not s.overrides[node_id]) and "ignored" or nil
    start_solve(player)
end

--- Shows the window as it was left: the last results, a running solve, or (after a restart or a
--- mod update, when only the targets are remembered) a fresh scan of them.
---@param player LuaPlayer
show_window = function(player)
    local s = gui.get_storage(player)
    if (s.built) then
        gui.show_progress(player, progress_caption(s.built))
    elseif (s.result) then
        gui.render(player, s.result)
    elseif (s.stopped) then
        gui.show_progress(player, { "gui.bottleneck-calc-extreme-stopped" })
    else
        s.surface_index = s.surface_index or player.surface.index
        run_scan(player)
    end
end

--- Shortcut button / ALT+B: open the window, or close it when it is already open.
---@param player LuaPlayer
local function toggle_window(player)
    if (gui.is_open(player)) then
        gui.force_close(player)
    else
        show_window(player)
    end
end

script.on_event(defines.events.on_lua_shortcut, function(e)
    if (e.prototype_name == "bottleneck-calc-extreme-shortcut") then
        toggle_window(game.get_player(e.player_index) --[[@as LuaPlayer]])
    end
end)

script.on_event("bottleneck-calc-extreme-custom-input", function(e)
    toggle_window(game.get_player(e.player_index) --[[@as LuaPlayer]])
end)

--- The window's tool button: put the selection tool in the cursor.
gui.callbacks.pick_tool = function(player)
    if (player.clear_cursor()) then
        player.cursor_stack.set_stack({ name = TOOL })
    end
end

---@param e EventData.on_player_selected_area | EventData.on_player_alt_selected_area | EventData.on_player_reverse_selected_area | EventData.on_player_alt_reverse_selected_area
local function on_player_selected_area(e)
    if (e.item ~= TOOL) then
        return
    end
    local player = game.get_player(e.player_index) ---@cast player -nil
    local s = gui.get_storage(player)
    if (s.built) then
        -- the targets can't change while solving: cancel or wait first
        player.create_local_flying_text({ text = { "gui.bottleneck-calc-extreme-busy" }, create_at_cursor = true })
        return
    end
    local remove = e.name == defines.events.on_player_reverse_selected_area
        or e.name == defines.events.on_player_alt_reverse_selected_area

    -- targets live on one surface: selecting on another one starts over there
    local changed, switched = false, false
    if (s.surface_index ~= e.surface.index) then
        if (remove) then
            return
        end
        changed = next(s.targets) ~= nil
        switched = true
        s.targets = {}
        s.speeds = {}
        s.pending_speeds = nil
        s.surface_index = e.surface.index
    end

    for _, entity in ipairs(e.entities) do
        local id = entity.unit_number
        if (id) then
            if (remove and s.targets[id]) then
                s.targets[id] = nil
                changed = true
            elseif (not remove and not s.targets[id]) then
                s.targets[id] = entity
                changed = true
            end
        end
    end

    if (changed and switched) then
        run_scan(player) -- another surface: starting over
    elseif (changed) then
        targets_changed(player)
    else
        show_window(player)
    end
end

script.on_event({
    defines.events.on_player_selected_area,
    defines.events.on_player_alt_selected_area,
    defines.events.on_player_reverse_selected_area,
    defines.events.on_player_alt_reverse_selected_area,
}, on_player_selected_area)

script.on_event(defines.events.on_tick, function(e)
    if (not storage.players) then
        return
    end
    for player_index, s in pairs(storage.players) do
        local built = s.built
        if (built) then
            local player = game.get_player(player_index)
            if (not player or not player.valid or not s.scan) then
                s.built = nil
            elseif (lp.step(built.lp, setting(player, "work-per-tick") --[[@as integer]])) then
                s.built = nil
                s.solved = built
                built.warm = nil
                s.result = model.results(built, s.scan, s.speeds)
                gui.render(player, s.result)
            elseif (e.tick % 2 == 0) then
                gui.update_progress(player, progress_caption(built))
            end
        end
        -- the report's Productivity section, a little each tick
        local job = s.prod_job
        if (job and job.phase ~= "done") then
            if (job.result ~= s.result or job.id ~= s.detail_item) then
                s.prod_job = nil
            elseif (detail.productivity_step(job, detail.PROD_WORK_PER_TICK)) then
                local player = game.get_player(player_index)
                if (player and player.valid) then
                    gui.update_prod(player)
                end
            end
        end
    end
end)

-- Pipette over an item, fluid or building in the window works like the game's smart pipette:
-- the item from your inventory if you have it, otherwise a ghost (fluids: whatever the game
-- picks for that fluid).
script.on_event("bottleneck-calc-extreme-pipette", function(e)
    local element = e.element
    if (not element or not element.valid) then
        return
    end
    local target = element.tags.bce_pipette --[[@as { type: string, name: string }?]]
    if (not target or not target.name) then
        return
    end
    local player = game.get_player(e.player_index)
    if (not player) then
        return
    end
    if (target.type == "fluid") then
        local fluid = prototypes.fluid[target.name]
        if (fluid) then
            player.pipette(fluid, nil, true)
        end
        return
    end
    local item
    if (target.type == "entity") then
        local entity = prototypes.entity[target.name]
        local places = entity and entity.items_to_place_this
        item = places and places[1] and prototypes.item[places[1].name]
    else
        item = prototypes.item[target.name]
    end
    if (item) then
        player.pipette(item, nil, true)
    end
end)

entity_tracker.on_unit_number_changed(function(event)
    if (not storage.players) then
        return
    end
    for _, s in pairs(storage.players) do
        if (s.targets and s.targets[event.from_unit_number]) then
            s.targets[event.from_unit_number] = nil
            s.targets[event.entity.unit_number] = event.entity
        end
    end
end)

-- Synchronous analysis for other mods and scripted tests: plain tables, no prototypes.
remote.add_interface("bottleneck-calc-extreme", {
    --- Number of buildings on the surface that consume an item (what "add consumers" would add).
    count_consumers = function(surface_index, force_name, item)
        local scan = model.scan(game.get_surface(surface_index), game.forces[force_name], {}, true)
        local n = 0
        for _, row in ipairs(scan.rows) do
            for _, a in ipairs(row.amounts) do
                if (a.amount < 0 and a.node.type == "item" and a.node.item.name == item) then
                    for _, entity in ipairs(row.entities) do
                        if (entity.valid) then n = n + 1 end
                    end
                    break
                end
            end
        end
        return n
    end,
    ---@param surface_index integer
    ---@param force_name string
    ---@param target_unit_numbers integer[]
    ---@param overrides table<string, string>? node id -> "ignored"
    ---@param use_analyzer boolean?
    ---@param track_steam boolean?
    ---@param speeds table<string, number>? part of a target row key -> speed
    analyze = function(surface_index, force_name, target_unit_numbers, overrides, use_analyzer, track_steam, speeds)
        local surface = game.get_surface(surface_index)
        local force = game.forces[force_name]
        if (not surface or not force) then
            return nil
        end
        local ids = {}
        for _, unit_number in pairs(target_unit_numbers) do
            ids[unit_number] = true
        end
        local scan = model.scan(surface, force, ids, use_analyzer ~= false)
        local by_key = {}
        for _, row in ipairs(scan.rows) do
            for pattern, speed in pairs(speeds or {}) do
                if (row.is_target and string.find(row.key, pattern, 1, true)) then
                    by_key[row.key] = speed
                end
            end
        end
        local built = model.build(scan, overrides or {}, track_steam, by_key)
        if (built.n_targets == 0) then
            return nil
        end
        while (not lp.step(built.lp, 1e12)) do
        end
        local result = model.results(built, scan, by_key)
        local items = {}
        for _, e in ipairs(result.items) do
            items[#items + 1] = { id = e.id, mode = e.mode, needed = e.needed, made = e.made, capacity = e.capacity,
                coverage = e.coverage }
        end
        local targets = {}
        for _, t in ipairs(result.targets) do
            targets[#targets + 1] = { key = t.row.key, count = t.row.count_max, speed = t.speed, reached = t.reached }
        end
        return {
            status = result.status,
            iterations = built.lp.iterations,
            work = built.lp.work,
            n_constraints = built.n_constraints,
            n_columns = built.lp.N,
            items = items,
            targets = targets,
            chain_buildings = result.chain_buildings,
            scanned_entities = result.scanned_entities,
        }
    end,
})

script.on_configuration_changed(function()
    if (storage.players) then
        for _, player in pairs(game.players) do
            gui.force_close(player)
        end
        -- scans hold prototypes and node ids that may be stale after mod changes
        for _, s in pairs(storage.players) do
            s.scan, s.built, s.solved, s.result, s.gui = nil, nil, nil, nil, nil
            -- without a scan a stopped window would show no targets: scan again on open
            s.stopped = nil
            -- left over from 0.1.x
            s.plan, s.tplan, s.refine, s.must_run, s.pending_must = nil, nil, nil, nil, nil
            -- "unlimited" is the only item override left ("free" was its old name)
            for id, mode in pairs(s.overrides or {}) do
                s.overrides[id] = (mode == "free" or mode == "ignored") and "ignored" or nil
            end
        end
    end
end)
