local flib_gui = require("__flib__.gui")
local api = require("__sw-rates-lib__.api-usage")
local detail = require("scripts.detail")

local gui = {
    events = {},
    ---@type { rescan: fun(player: LuaPlayer), reset: fun(player: LuaPlayer), remove_targets: fun(player: LuaPlayer, unit_numbers: integer[]), set_speed: fun(player: LuaPlayer, row_key: string, speed: number), add_consumers: fun(player: LuaPlayer, item: string), toggle_item: fun(player: LuaPlayer, node_id: string), pick_tool: fun(player: LuaPlayer) }
    callbacks = {},
}

local main_window_name = "bottleneck-calc-extreme_wnd_main"

---@class BCE.PlayerStorage
---@field gui? BCE.GuiElements
---@field is_pinned? true
---@field targets table<integer, LuaEntity>
---@field surface_index? integer
---@field scan? BCE.Scan
---@field built? table being solved
---@field solved? table
---@field result? BCE.Result
---@field detail_item? string node id of the item report shown under the targets
---@field jump? { ri: integer, i: integer } last building jumped to from the item report
---@field highlights? LuaRenderObject[] green boxes around the buildings jumped to
---@field overrides table<string, string>
---@field speeds table<string, number>
---@field ignore_close_tick? integer

---@class BCE.GuiElements
---@field wnd_main LuaGuiElement
---@field button_pin LuaGuiElement
---@field button_close LuaGuiElement
---@field label_status LuaGuiElement
---@field table_items LuaGuiElement?
---@field table_targets LuaGuiElement

---@param player LuaPlayer
---@return BCE.PlayerStorage
function gui.get_storage(player)
    if (not storage.players) then
        storage.players = {}
    end
    local s = storage.players[player.index]
    if (not s) then
        s = {}
        storage.players[player.index] = s
    end
    s.overrides = s.overrides or {}
    s.targets = s.targets or {}
    s.speeds = s.speeds or {}
    return s
end

---@param player LuaPlayer
local function close_main_window(player)
    local window = player.gui.screen[main_window_name]
    if (window) then
        window.destroy()
    end
    gui.get_storage(player).gui = nil
end

---@param player LuaPlayer
---@return boolean
function gui.is_open(player)
    local window = player.gui.screen[main_window_name]
    return window ~= nil and window.valid
end

---@param player LuaPlayer
function gui.force_close(player)
    close_main_window(player)
end

---@param e EventData.on_gui_closed
local function on_window_closed(e)
    local player = game.get_player(e.player_index) ---@cast player -nil
    local s = gui.get_storage(player)
    if (s.is_pinned or s.ignore_close_tick == e.tick) then
        return
    end
    close_main_window(player)
end

---@param e EventData.on_gui_click
local function on_pin_button_click(e)
    local player = game.get_player(e.player_index) ---@cast player -nil
    local s = gui.get_storage(player)
    if (not s.gui) then
        return
    end
    -- Pinned = compact view: rebuild the window in the other layout, keeping its position.
    s.is_pinned = (not s.is_pinned) or nil
    local old = s.gui.wnd_main
    local location = old.valid and old.location
    local caption = s.gui.label_status.valid and s.gui.label_status.caption or ""
    close_main_window(player)
    if (s.result and not s.built) then
        gui.render(player, s.result)
    else
        gui.show_progress(player, caption)
    end
    if (location and s.gui) then
        s.gui.wnd_main.location = location
    end
end

---@param e EventData.on_gui_click
local function on_close_button_click(e)
    close_main_window(game.get_player(e.player_index) --[[@as LuaPlayer]])
end

---@param e EventData.on_gui_click
local function on_rescan_button_click(e)
    gui.callbacks.rescan(game.get_player(e.player_index) --[[@as LuaPlayer]])
end

---@param e EventData.on_gui_click
local function on_pick_tool_click(e)
    gui.callbacks.pick_tool(game.get_player(e.player_index) --[[@as LuaPlayer]])
end

---@param e EventData.on_gui_click
local function on_reset_button_click(e)
    gui.callbacks.reset(game.get_player(e.player_index) --[[@as LuaPlayer]])
end

--- An item dropped on the "add consumers" slot: every building using it becomes a target.
---@param e EventData.on_gui_elem_changed
local function on_consumers_elem_changed(e)
    local item = e.element.elem_value --[[@as string?]]
    e.element.elem_value = nil
    if (item) then
        gui.callbacks.add_consumers(game.get_player(e.player_index) --[[@as LuaPlayer]], item)
    end
end

--- Item icons: click shows its report under the targets; right-click treats the item as
--- unlimited, or counts it again.
---@param e EventData.on_gui_click
local function on_item_button_click(e)
    local node_id = e.element.tags.node_id --[[@as string?]]
    if (not node_id) then
        return
    end
    local player = game.get_player(e.player_index) --[[@as LuaPlayer]]
    if (e.button == defines.mouse_button_type.left) then
        gui.show_item_detail(player, node_id)
    elseif (e.button == defines.mouse_button_type.right and e.element.tags.can_toggle) then
        gui.callbacks.toggle_item(player, node_id)
    end
end

--- Target building icons: click removes those buildings from the targets.
---@param e EventData.on_gui_click
local function on_building_button_click(e)
    local player = game.get_player(e.player_index) ---@cast player -nil
    local s = gui.get_storage(player)
    local key = e.element.tags.row_key --[[@as string?]]
    if (not key or not s.scan or not e.element.tags.removable or e.button ~= defines.mouse_button_type.left) then
        return
    end
    for _, r in ipairs(s.scan.rows) do
        if (r.key == key and r.is_target) then
            gui.callbacks.remove_targets(player, r.entity_ids)
            return
        end
    end
end

--- Speeds a target group can be set to, in percent: one slider notch each.
local SPEED_STEPS = { 0, 10, 20, 30, 40, 50, 60, 80, 100, 150, 200 }

--- Slider notch closest to a speed.
---@param speed number 1 = 100%
---@return integer
local function speed_step(speed)
    local best, best_d = 1, math.huge
    for i, pct in ipairs(SPEED_STEPS) do
        local d = math.abs(pct - speed * 100)
        if (d < best_d) then
            best, best_d = i, d
        end
    end
    return best
end

---@param speed number
---@param pending boolean? not applied yet
local function speed_caption(speed, pending)
    local text = string.format("%d%%", math.floor(speed * 100 + 0.5))
    return pending and ("[color=yellow]" .. text .. "[/color]") or text
end

---@param s BCE.PlayerStorage
local function update_apply_button(s)
    local tf = s.gui and s.gui.table_targets
    if (not (tf and tf.valid)) then
        return
    end
    local flow = tf.bce_apply_flow
    local button = flow and flow.bce_apply_speeds
    if (button and button.valid) then
        button.enabled = s.pending_speeds ~= nil
    end
end

--- A slider moved: show the Apply button.
---@param s BCE.PlayerStorage
local function show_apply_button(s)
    local tf = s.gui and s.gui.table_targets
    local flow = tf and tf.valid and tf.bce_apply_flow
    if (flow and flow.valid) then
        flow.visible = true
    end
    update_apply_button(s)
end

--- Speed of a target group. Moving the slider only marks the new speed; the Apply button
--- works it out, so nothing starts while the player is still choosing.
---@param e EventData.on_gui_value_changed
local function on_speed_changed(e)
    local player = game.get_player(e.player_index) ---@cast player -nil
    local s = gui.get_storage(player)
    local key = e.element.tags.row_key --[[@as string]]
    local step = math.max(1, math.min(#SPEED_STEPS, math.floor(e.element.slider_value + 0.5)))
    local speed = SPEED_STEPS[step] / 100
    local current = s.speeds[key] or 1
    local pending = s.pending_speeds or {}
    if (math.abs(speed - current) < 1e-9) then
        pending[key] = nil
    else
        pending[key] = speed
    end
    s.pending_speeds = next(pending) and pending or nil
    local label = e.element.parent and e.element.parent.bce_speed_label
    if (label and label.valid) then
        label.caption = speed_caption(speed, pending[key] ~= nil)
    end
    show_apply_button(s)
end

--- Work out the report for the speeds chosen on the sliders.
---@param e EventData.on_gui_click
local function on_apply_speeds_click(e)
    local player = game.get_player(e.player_index) ---@cast player -nil
    local s = gui.get_storage(player)
    local pending = s.pending_speeds
    s.pending_speeds = nil
    update_apply_button(s)
    for key, speed in pairs(pending or {}) do
        gui.callbacks.set_speed(player, key, speed)
    end
end

local WINDOW_HEIGHT_FRACTION = 0.72

---@param player LuaPlayer
---@return number
local function get_max_height(player)
    return player.display_resolution.height / player.display_scale * WINDOW_HEIGHT_FRACTION
end

---@param player LuaPlayer
local function resize_main_window(player)
    local s = gui.get_storage(player)
    if (s.gui) then
        local wnd_main = s.gui.wnd_main
        if (wnd_main and wnd_main.valid) then
            wnd_main.style.maximal_height = get_max_height(player)
        else
            close_main_window(player)
        end
    end
end

function gui.events.on_player_display_resolution_changed(e)
    resize_main_window(game.get_player(e.player_index) --[[@as LuaPlayer]])
end

function gui.events.on_player_display_scale_changed(e)
    resize_main_window(game.get_player(e.player_index) --[[@as LuaPlayer]])
end

flib_gui.add_handlers({
    on_window_closed = on_window_closed,
    on_pin_button_click = on_pin_button_click,
    on_close_button_click = on_close_button_click,
    on_rescan_button_click = on_rescan_button_click,
    on_reset_button_click = on_reset_button_click,
    on_pick_tool_click = on_pick_tool_click,
    on_item_button_click = on_item_button_click,
    on_consumers_elem_changed = on_consumers_elem_changed,
    on_building_button_click = on_building_button_click,
    on_speed_changed = on_speed_changed,
    on_apply_speeds_click = on_apply_speeds_click,
}, nil, "bce")

local function frame_action_button(name, sprite, tooltip, handler)
    return {
        type = "sprite-button",
        name = name,
        style = "frame_action_button",
        sprite = sprite,
        tooltip = tooltip,
        mouse_button_filter = { "left" },
        handler = { [defines.events.on_gui_click] = handler },
    }
end

local function pane(caption, content)
    return {
        type = "frame",
        style = "inside_shallow_frame",
        direction = "vertical",
        {
            type = "frame",
            style = "subheader_frame",
            { type = "label", style = "subheader_caption_label", caption = caption },
            { type = "empty-widget", style = "flib_horizontal_pusher" },
        },
        {
            type = "scroll-pane",
            horizontal_scroll_policy = "never",
            vertical_scroll_policy = "auto-and-reserve-space",
            style = "flib_naked_scroll_pane",
            style_mods = { top_padding = 8, bottom_padding = 8, horizontally_stretchable = true },
            content
        }
    }
end

---@param player LuaPlayer
---@return BCE.GuiElements
function gui.build(player)
    local s = gui.get_storage(player)
    if (s.gui and s.gui.wnd_main.valid) then
        return s.gui
    end
    local existing = player.gui.screen[main_window_name]
    if (existing) then
        existing.destroy()
    end

    local compact = s.is_pinned == true
    local status_flow = {
        type = "flow",
        direction = "horizontal",
        style_mods = { vertical_align = "center" },
        {
            type = "label",
            name = "label_status",
            caption = "",
            style_mods = { single_line = false, maximal_width = 900 },
        },
        { type = "empty-widget", style = "flib_horizontal_pusher" },
    }
    if (not compact) then
        status_flow[#status_flow + 1] = {
            type = "sprite-button",
            sprite = "item/bottleneck-calc-extreme-tool",
            tooltip = { "gui.bottleneck-calc-extreme-pick-tool" },
            style = "slot_button",
            style_mods = { left_margin = 16 },
            handler = { [defines.events.on_gui_click] = on_pick_tool_click },
        }
    end
    status_flow[#status_flow + 1] = {
        type = "label",
        caption = { "gui.bottleneck-calc-extreme-add-consumers" },
        tooltip = { "gui.bottleneck-calc-extreme-add-consumers-tooltip" },
        style_mods = { left_margin = 16 },
    }
    status_flow[#status_flow + 1] = {
        type = "choose-elem-button",
        elem_type = "item",
        tooltip = { "gui.bottleneck-calc-extreme-add-consumers-tooltip" },
        handler = { [defines.events.on_gui_elem_changed] = on_consumers_elem_changed },
    }
    -- children are read as an array: no nil gaps, or flib silently skips everything after one
    local panes = {
        type = "flow",
        style = "inset_frame_container_horizontal_flow",
        direction = "horizontal",
    }
    panes[#panes + 1] = pane({ "gui.bottleneck-calc-extreme-pane-items" }, {
        type = "flow",
        name = "table_items",
        direction = "vertical",
        style_mods = { minimal_width = compact and 0 or 520, vertical_spacing = 0, left_padding = 8, right_padding = 8 },
    })
    panes[#panes + 1] = pane({ "gui.bottleneck-calc-extreme-pane-targets" }, {
        type = "flow",
        name = "table_targets",
        direction = "vertical",
        style_mods = { vertical_spacing = 4, left_padding = 8, right_padding = 8 },
    })

    local elems = flib_gui.add(player.gui.screen, {
        type = "frame",
        name = main_window_name,
        handler = { [defines.events.on_gui_closed] = on_window_closed },
        style_mods = { maximal_height = get_max_height(player) },
        direction = "vertical",
        {
            type = "flow",
            style = "flib_titlebar_flow",
            drag_target = main_window_name,
            {
                type = "label",
                style = "flib_frame_title",
                caption = { "gui.bottleneck-calc-extreme-title" },
                ignored_by_interaction = true
            },
            { type = "empty-widget", style = "flib_titlebar_drag_handle", ignored_by_interaction = true },
            frame_action_button("button_reset", "utility/reset_white", { "gui.bottleneck-calc-extreme-reset" },
                on_reset_button_click),
            {
                -- icon and word: the one button you press all the time, so easy to find
                type = "button",
                name = "button_rescan",
                style = "frame_button",
                caption = { "", "[img=bottleneck-calc-extreme-refresh-white] ", { "gui.bottleneck-calc-extreme-refresh-caption" } },
                tooltip = { "gui.bottleneck-calc-extreme-rescan" },
                mouse_button_filter = { "left" },
                style_mods = { height = 24, left_padding = 6, right_padding = 8, font = "default-semibold",
                    font_color = { 1, 1, 1 }, hovered_font_color = { 0, 0, 0 }, clicked_font_color = { 0, 0, 0 } },
                handler = { [defines.events.on_gui_click] = on_rescan_button_click },
            },
            frame_action_button("button_pin", "flib_pin_white", { "gui.bottleneck-calc-extreme-pin" }, on_pin_button_click),
            frame_action_button("button_close", "utility/close", { "gui.close-instruction" }, on_close_button_click)
        },
        {
            type = "frame",
            style = "inside_shallow_frame_with_padding",
            style_mods = { horizontally_stretchable = true, bottom_margin = 8 },
            status_flow,
        },
        panes,
    }) --[[@as BCE.GuiElements]]

    elems.wnd_main = elems[main_window_name]
    elems[main_window_name] = nil
    elems.wnd_main.auto_center = true

    s.gui = elems
    if (s.is_pinned) then
        elems.button_pin.toggled = true
        elems.button_pin.tooltip = { "gui.bottleneck-calc-extreme-unpin" }
        elems.button_close.tooltip = { "gui.close" }
    else
        player.opened = elems.wnd_main
    end
    elems.wnd_main.bring_to_front()
    return elems
end

---@param player LuaPlayer
---@param caption LocalisedString
function gui.show_progress(player, caption)
    local ui = gui.build(player)
    if (ui.table_items) then
        ui.table_items.clear()
    end
    ui.table_targets.clear()
    ui.label_status.caption = caption
end

--- Only the status line: the last results stay visible while a new answer is worked out.
---@param player LuaPlayer
---@param caption LocalisedString
function gui.update_progress(player, caption)
    local s = gui.get_storage(player)
    if (s.gui and s.gui.label_status.valid) then
        s.gui.label_status.caption = caption
    end
end

-- ---------------------------------------------------------------------------
-- cells

local function create_count_label(text)
    return {
        type = "label",
        caption = text,
        ignored_by_interaction = true,
        style_mods = {
            width = 36,
            height = 36,
            left_margin = -35,
            right_margin = -1,
            bottom_margin = -4,
            font = "item-count",
            horizontal_align = "right",
            vertical_align = "bottom",
            single_line = true
        },
    }
end

local function create_count_qualifier(text)
    return {
        type = "label",
        caption = text,
        ignored_by_interaction = true,
        style_mods = {
            width = 36,
            height = 36,
            left_margin = -35,
            right_margin = -1,
            font = "default-tiny-bold",
            horizontal_align = "right",
            vertical_align = "top",
            single_line = true
        },
    }
end

---@param button Rates.Gui.ButtonDescription
---@param count LocalisedString?
---@param pipette { type: string, name: string }? makes the icon smart-pipettable (still not a button)
local function create_icon_from_button(button, count, pipette)
    local flow = {
        type = "flow",
        style = "packed_horizontal_flow",
        elem_tooltip = button.elem_tooltip,
        tooltip = button.tooltip,
    }
    if (button.sprite) then
        flow[#flow + 1] = {
            type = "sprite-button",
            style = "transparent_slot",
            ignored_by_interaction = true,
            sprite = button.sprite,
            quality = button.quality and button.quality.name,
        }
    elseif (count or button.qualifier) then
        flow[#flow + 1] = {
            type = "sprite-button",
            style = "transparent_slot",
            ignored_by_interaction = true,
            sprite = "virtual-signal/signal-question-mark"
        }
    end
    if (count) then
        flow[#flow + 1] = create_count_label(count)
    end
    if (button.qualifier) then
        flow[#flow + 1] = create_count_qualifier(button.qualifier.text)
    end
    local b = flow[1]
    if (pipette and b and button.sprite) then
        -- the pipette key reads the hovered element, so it must receive the mouse; the
        -- tooltip moves to it, since the flow no longer gets the hover
        b.ignored_by_interaction = false
        b.tags = { bce_pipette = pipette }
        b.tooltip = flow.tooltip
        b.elem_tooltip = flow.elem_tooltip
        flow.tooltip = nil
        flow.elem_tooltip = nil
    end
    return flow
end

local function create_node_icon(ui, count, pipette)
    return create_icon_from_button(api.gui.gui_button(ui), count, pipette)
end

--- What the pipette picks from a recipe icon: its main product, when that is an item or fluid.
---@param conf Rates.Configuration
---@return { type: string, name: string }?
local function recipe_pipette(conf)
    if (conf.type == "meta" and conf.children) then
        conf = conf.children[1]
    end
    local recipe = conf and conf.recipe
    if (not recipe) then
        return nil
    end
    local product = recipe.main_product or (recipe.products and #recipe.products == 1 and recipe.products[1])
    if (product and (product.type == "item" or product.type == "fluid")) then
        return { type = product.type, name = product.name }
    end
    return nil
end

--- What the pipette picks from an item or fluid icon.
---@param node Rates.Node
---@return { type: string, name: string }?
local function node_pipette(node)
    if (node.type == "item") then
        return { type = "item", name = node.item.name }
    elseif (node.type == "fluid") then
        return { type = "fluid", name = node.fluid.name }
    end
    return nil
end

local color_red = { r = 1, g = 0.35, b = 0.35 }
local color_green = { r = 0.45, g = 1, b = 0.45 }
local color_yellow = { r = 1, g = 0.85, b = 0.3 }
local color_grey = { r = 0.7, g = 0.7, b = 0.7 }

---@param x number 1 = 100%
local function percent(x)
    if (x >= 10) then
        -- far more than needed: a multiple reads better than "12345%"
        return x >= 1000 and "×999+" or string.format("×%.0f", x)
    elseif (x >= 0.1) then
        return string.format("%.0f%%", x * 100)
    end
    return string.format("%.1f%%", x * 100)
end

---@param row BCE.Row
local function cell_annotations(row)
    local annotations = row.annotations
    if (annotations == nil or #annotations == 0) then
        return { type = "label", caption = "" }
    end
    local severity = 0
    local tips = { "" }
    for _, annotation in ipairs(annotations) do
        local g = api.configuration.gui_annotation(annotation, row.conf)
        if (g.severity == "error") then
            severity = math.max(severity, 3)
        elseif (g.severity == "warning") then
            severity = math.max(severity, 2)
        elseif (g.severity == "information") then
            severity = math.max(severity, 1)
        end
        if (#tips > 1) then
            tips[#tips + 1] = "\n\n"
        end
        if (g.icon) then
            tips[#tips + 1] = "[img=" .. g.icon.sprite .. "]  "
        end
        tips[#tips + 1] = g.text
    end
    local sprite = "virtual-signal.signal-info"
    if (severity == 3) then
        sprite = "virtual-signal.signal-no-entry"
    elseif (severity == 2) then
        sprite = "utility.warning_icon"
    end
    return {
        type = "sprite",
        sprite = sprite,
        tooltip = tips,
        style_mods = { stretch_image_to_widget_size = true, width = 24, height = 24 },
    }
end

---@param row BCE.Row
---@param removable boolean click removes this target group
local function cell_entity(row, removable)
    local button = api.gui.gui_button(api.configuration.gui_entity(row.conf))
    local icon = create_icon_from_button(button, tostring(row.count_max))
    local b = icon[1]
    if (b) then
        b.ignored_by_interaction = false
        if (removable) then
            b.style = "flib_slot_button_default"
            b.style_mods = { size = 36 }
            b.tooltip = { "", button.tooltip or "", (button.tooltip and "\n" or ""),
                { "gui.bottleneck-calc-extreme-click-to-remove" } }
            b.handler = { [defines.events.on_gui_click] = on_building_button_click }
        else
            b.tooltip = button.tooltip
        end
        b.elem_tooltip = button.elem_tooltip
        b.tags = { row_key = row.key, removable = removable or nil, bce_pipette = { type = "entity", name = row.conf.entity and row.conf.entity.name
            or (row.conf.children and row.conf.children[1].entity and row.conf.children[1].entity.name) } }
        icon.tooltip = nil
        icon.elem_tooltip = nil
    end

    local flow = { type = "flow", style = "packed_horizontal_flow", icon }
    local conf = row.conf
    if (conf.type == "meta") then
        conf = conf.children[1]
    end
    local module_effects = conf.module_effects
    if (module_effects) then
        for _, module in ipairs(module_effects.modules or {}) do
            flow[#flow + 1] = create_node_icon(api.node.gui_default(api.node.create.item(module.module, module.quality)),
                nil, { type = "item", name = module.module.name })
            flow[#flow + 1] = create_count_label(tostring(module.count))
        end
        for _, beacon in ipairs(module_effects.beacons or {}) do
            if (not beacon.beacon.hidden) then
                flow[#flow + 1] = create_node_icon(api.node.gui_default(
                    api.node.create.map_entity(beacon.beacon, beacon.quality)), nil,
                    { type = "entity", name = beacon.beacon.name })
                flow[#flow + 1] = create_count_label(tostring(beacon.count))
            end
            for _, module in ipairs(beacon.per_beacon_modules) do
                flow[#flow + 1] = create_node_icon(api.node.gui_default(
                    api.node.create.item(module.module, module.quality)), nil,
                    { type = "item", name = module.module.name })
                flow[#flow + 1] = create_count_label(tostring(module.count))
            end
        end
    end
    return flow
end

--- Speed slider of a target group, with its percentage and what the group makes at that speed.
---@param row BCE.Row
---@param speed number
---@param pending boolean speed chosen on the slider but not applied yet
local function cell_speed(row, speed, pending)
    local made = ""
    for _, a in ipairs(row.amounts) do
        if (a.amount > 0 and (a.node.type == "item" or a.node.type == "fluid")) then
            local ui = api.node.gui_default(a.node)
            made = { "", "[", a.node.type, "=", a.node.type == "item" and a.node.item.name or a.node.fluid.name, "] ",
                api.gui.gui_amount_text(ui, a.amount * row.count_max * speed) }
            break
        end
    end
    return {
        type = "flow",
        direction = "horizontal",
        style_mods = { vertical_align = "center", left_margin = 8 },
        {
            type = "slider",
            minimum_value = 1,
            maximum_value = #SPEED_STEPS,
            value = speed_step(speed),
            value_step = 1,
            discrete_values = true,
            tooltip = { "gui.bottleneck-calc-extreme-speed-tooltip" },
            tags = { row_key = row.key },
            style_mods = { width = 120 },
            handler = { [defines.events.on_gui_value_changed] = on_speed_changed },
        },
        {
            type = "label",
            name = "bce_speed_label",
            caption = speed_caption(speed, pending),
            style_mods = { font = "default-bold", minimal_width = 40, horizontal_align = "right" },
        },
        { type = "label", caption = made, style_mods = { font_color = color_grey, left_margin = 4 } },
    }
end

-- ---------------------------------------------------------------------------
-- items pane

local function node_type(node)
    local t = node.type
    if (t == "item") then return 10 end
    if (t == "fluid") then return 11 end
    if (t == "any") then
        local details = node.details
        if (details and details.type == "any-fluid") then return 11 end
    end
    return 100
end

--- Items used or made below this (per second) are solver rounding noise.
local FLOW_TOL = 1e-5

--- can make − needed, red or green with its sign; "" when it is basically 0 (an item exactly
--- at its limit), which is only noise.
---@param capacity number
---@param needed number
---@param fmt fun(x: number): LocalisedString amount with its unit
---@return LocalisedString
local function difference_caption(capacity, needed, fmt)
    local diff = capacity - needed
    if (math.abs(diff) > 1e-4 * math.max(needed, capacity) and math.abs(diff) > FLOW_TOL) then
        return { "", "[color=", diff < 0 and "#ff6060" or "#70e070", "]",
            diff < 0 and "−" or "+", fmt(math.abs(diff)), "[/color]" }
    end
    return ""
end

--- Compact view: how many short items are listed.
local COMPACT_SHORT_ROWS = 20

--- Fixed column widths: the two Enough tables (and Short) line up.
local ITEM_NAME_WIDTH = 220
local COLUMN_WIDTHS = { 70, 70, 80, 60 }

---@param e BCE.Item
local function item_icon(e)
    local ui = api.node.gui_default(e.node)
    local data = api.gui.gui_button_and_text(ui, nil)
    local icon = create_icon_from_button(data.button)
    local button = icon[1]
    if (button) then
        local clickable = e.mode == "counted" or e.default_mode == "counted"
        button.ignored_by_interaction = false
        button.handler = { [defines.events.on_gui_click] = on_item_button_click }
        local own = data.button.tooltip ~= "" and data.button.tooltip or nil
        if (clickable) then
            button.style = e.mode == "counted" and "flib_slot_button_default" or "flib_slot_button_green"
            button.tooltip = { "", own or "", (own and "\n\n" or ""),
                { e.mode == "counted" and "gui.bottleneck-calc-extreme-item-click-unlimited"
                    or "gui.bottleneck-calc-extreme-item-click-count" },
                "\n", { "gui.bottleneck-calc-extreme-item-right-click" } }
        else
            button.style_mods = { margin = 4 }
            button.tooltip = { "", own or "", (own and "\n\n" or ""),
                { "gui.bottleneck-calc-extreme-item-right-click" } }
        end
        button.tags = { node_id = e.id, can_toggle = clickable or nil,
            bce_pipette = node_pipette(e.node) }
        button.elem_tooltip = data.button.elem_tooltip
        icon.tooltip = nil
        icon.elem_tooltip = nil
    end
    return {
        type = "flow",
        style = "packed_horizontal_flow",
        style_mods = { vertical_align = "center" },
        icon,
        { type = "label", caption = data.text, style_mods = { left_margin = 4, width = ITEM_NAME_WIDTH } },
    }
end

---@param e BCE.Item
---@param x number
local function amount(e, x)
    return api.gui.gui_amount_text(api.node.gui_default(e.node), x)
end

--- Section caption; with a help key it gets an info icon whose tooltip explains the section.
---@param caption LocalisedString
---@param help string?
local function header_def(caption, help)
    local def = {
        type = "label",
        caption = caption,
        style = "caption_label",
        style_mods = { top_margin = 6 },
    }
    if (help) then
        def.caption = { "", caption, " [img=info]" }
        def.tooltip = { "gui.bottleneck-calc-extreme-help-" .. help }
    end
    return def
end

--- Enough items above this coverage are surplus: only the most over-covered of them are listed.
local SURPLUS_COVERAGE = 1.25
--- How many of the most over-covered items to list after the skipped ones.
local SURPLUS_ROWS = 20

--- A section of items with their need and what can be made.
---@param parent LuaGuiElement
---@param caption LocalisedString
---@param help string
---@param list BCE.Item[]
---@param max_rows integer
---@param kind "short" | "enough" | "used"
---@param compact boolean only the difference column, and fewer rows
local function item_section(parent, caption, help, list, max_rows, kind, compact)
    if (#list == 0) then
        if (kind == "short") then
            flib_gui.add(parent, header_def(caption, help))
            flib_gui.add(parent, { type = "label", caption = { "gui.bottleneck-calc-extreme-no-shortages" } })
        end
        return
    end
    flib_gui.add(parent, header_def(caption, help))
    if (compact and kind == "enough") then
        -- compact: only how many are close to their limit and how many have plenty
        local balanced = 0
        while (balanced < #list and list[balanced + 1].coverage <= SURPLUS_COVERAGE) do
            balanced = balanced + 1
        end
        for _, line in ipairs({ { "gui.bottleneck-calc-extreme-enough-balanced", tostring(balanced), balanced },
            { "gui.bottleneck-calc-extreme-enough-surplus", tostring(#list - balanced), #list - balanced } }) do
            if (line[3] > 0) then
                flib_gui.add(parent, { type = "label", caption = { line[1], line[2] }, style_mods = { font_color = color_grey } })
            end
        end
        return
    end
    local columns = (kind == "used" or compact) and 2 or 5
    local function new_table()
        local tbl = parent.add({ type = "table", column_count = columns })
        tbl.style.horizontal_spacing = 12
        tbl.style.vertical_spacing = 0
        for c = 2, columns do
            tbl.style.column_alignments[c] = "right"
        end
        return tbl
    end
    local function cell(caption, c, mods)
        mods = mods or {}
        mods.minimal_width = COLUMN_WIDTHS[c]
        mods.horizontal_align = "right"
        return { type = "label", caption = caption, style_mods = mods }
    end
    local function add_headers(t)
        local grey = function() return { font_color = color_grey } end
        if (compact) then
            flib_gui.add(t, { { type = "label", caption = "" },
                cell({ "gui.bottleneck-calc-extreme-col-difference" }, 3, grey()) })
            return
        end
        local coverage = cell({ "gui.bottleneck-calc-extreme-col-coverage" }, 4, grey())
        coverage.tooltip = { "gui.bottleneck-calc-extreme-col-coverage-tooltip" }
        flib_gui.add(t, {
            { type = "label", caption = "" },
            cell({ "gui.bottleneck-calc-extreme-col-needed" }, 1, grey()),
            cell({ "gui.bottleneck-calc-extreme-col-can-make" }, 2, grey()),
            cell({ "gui.bottleneck-calc-extreme-col-difference" }, 3, grey()),
            coverage,
        })
    end
    local tbl = new_table()

    local function add_row(t, e)
        if (kind == "used") then
            flib_gui.add(t, {
                item_icon(e),
                { type = "label", caption = { "gui.bottleneck-calc-extreme-row-used", amount(e, e.needed) } },
            })
            return
        end
        local diff_caption = difference_caption(e.capacity, e.needed, function(x) return amount(e, x) end)
        if (compact) then
            flib_gui.add(t, { item_icon(e), cell(diff_caption, 3) })
            return
        end
        local shown = percent(e.coverage)
        local color
        if (kind == "short") then
            -- short by a hair: it reads 100%, so it looks like the items just keeping up
            color = shown == "100%" and color_yellow or color_red
        else
            color = e.coverage < 1.05 and color_yellow or color_green
        end
        flib_gui.add(t, {
            item_icon(e),
            cell(amount(e, e.needed), 1),
            cell(amount(e, e.capacity), 2),
            cell(diff_caption, 3),
            cell(shown, 4, { font = "default-bold", font_color = color }),
        })
    end

    -- Enough: the items close to running short, then (when there are many more) only the most
    -- over-covered ones
    local shown_rows = math.min(#list, max_rows)
    local close = #list
    if (kind == "short" and compact) then
        shown_rows = math.min(#list, COMPACT_SHORT_ROWS)
    elseif (kind == "enough") then
        close = 0
        while (close < #list and list[close + 1].coverage <= SURPLUS_COVERAGE) do
            close = close + 1
        end
        shown_rows = math.min(shown_rows, close)
        if (not compact and #list - shown_rows <= SURPLUS_ROWS) then
            shown_rows = #list
        end
    end
    if (kind ~= "used" and shown_rows > 0) then
        add_headers(tbl)
    end
    for i = 1, shown_rows do
        add_row(tbl, list[i])
    end
    if (shown_rows < #list) then
        local rest = tostring(#list - shown_rows)
        if (compact and kind == "short") then
            -- sorted by coverage: the rest are all at least as covered as the first one left out
            flib_gui.add(parent, { type = "label", style_mods = { font_color = color_grey },
                caption = { "gui.bottleneck-calc-extreme-short-more", rest, percent(list[shown_rows + 1].coverage) } })
        elseif (kind == "enough" and not compact) then
            local tail = math.max(shown_rows + 1, #list - SURPLUS_ROWS + 1)
            flib_gui.add(parent, { type = "label", caption = { "gui.bottleneck-calc-extreme-surplus-skipped",
                tostring(tail - 1 - shown_rows) }, style_mods = { font_color = color_grey } })
            local t2 = new_table()
            add_headers(t2)
            for i = tail, #list do
                add_row(t2, list[i])
            end
        else
            flib_gui.add(parent, { type = "label", caption = { "gui.bottleneck-calc-extreme-more", tostring(#list - shown_rows) } })
        end
    end
end

---@param result BCE.Result
---@param short BCE.Item[]
---@param compact boolean
local function status_caption(result, short, compact)
    local caption = { "" }
    local first = short[1]
    if (first) then
        local ui = api.node.gui_default(first.node)
        local name = api.gui.gui_button_and_text(ui, nil).text
        caption[#caption + 1] = compact and { "gui.bottleneck-calc-extreme-summary-short-compact", name, percent(first.coverage) }
            or { "gui.bottleneck-calc-extreme-summary-short", name, percent(first.coverage), tostring(#short) }
    else
        caption[#caption + 1] = { "gui.bottleneck-calc-extreme-summary-covered" }
    end
    if (not compact) then
        caption[#caption + 1] = "\n"
        caption[#caption + 1] = { "gui.bottleneck-calc-extreme-summary-chain", tostring(result.target_entities),
            tostring(result.chain_buildings) }
    end
    for _, t in ipairs(result.targets) do
        if (t.reached < 0.999) then
            caption[#caption + 1] = "\n"
            caption[#caption + 1] = { "gui.bottleneck-calc-extreme-target-unreachable", percent(t.reached) }
            break
        end
    end
    if (result.status ~= "optimal") then
        caption[#caption + 1] = "\n"
        caption[#caption + 1] = { "gui.bottleneck-calc-extreme-status-" .. result.status }
    end
    if (result.target_entities_without_conf > 0) then
        caption[#caption + 1] = "\n"
        caption[#caption + 1] = { "gui.bottleneck-calc-extreme-targets-idle", tostring(result.target_entities_without_conf) }
    end
    return caption
end

local render_detail ---@type fun(parent: LuaGuiElement, s: BCE.PlayerStorage, result: BCE.Result)

-- ---------------------------------------------------------------------------
-- item report

--- Rows listed per part of the report.
local DETAIL_ROWS = 15

local render_targets ---@type fun(player: LuaPlayer, s: BCE.PlayerStorage, ui: BCE.GuiElements, result: BCE.Result)

---@param e EventData.on_gui_click
local function on_detail_item_click(e)
    local id = e.element.tags.detail_id --[[@as string?]]
    if (id) then
        gui.show_item_detail(game.get_player(e.player_index) --[[@as LuaPlayer]], id)
    end
end

---@param e EventData.on_gui_click
local function on_detail_close_click(e)
    local player = game.get_player(e.player_index) --[[@as LuaPlayer]]
    gui.show_item_detail(player, nil)
end

---@param e EventData.on_gui_click
local function on_detail_refresh_click(e)
    local player = game.get_player(e.player_index) --[[@as LuaPlayer]]
    gui.show_item_detail(player, gui.get_storage(player).detail_item)
end

--- How long the green boxes stay, in ticks.
local HIGHLIGHT_TICKS = 12 * 60
local HIGHLIGHT_COLOR = { r = 0, g = 0.9, b = 0, a = 1 }

--- Building icon in the item report: show those buildings on the map, one after the other on
--- each click, with green boxes around all of them for a while.
---@param e EventData.on_gui_click
local function on_detail_building_click(e)
    if (e.button ~= defines.mouse_button_type.left) then
        return
    end
    local player = game.get_player(e.player_index) ---@cast player -nil
    local s = gui.get_storage(player)
    local ri = e.element.tags.jump_row --[[@as integer?]]
    local row = ri and s.scan and s.scan.rows[ri]
    if (not row) then
        return
    end
    local valid = {} ---@type LuaEntity[]
    for _, entity in ipairs(row.entities or {}) do
        if (entity.valid) then
            valid[#valid + 1] = entity
        end
    end
    if (#valid == 0) then
        return
    end
    local i = (s.jump and s.jump.ri == ri) and (s.jump.i % #valid) + 1 or 1
    s.jump = { ri = ri, i = i }
    local target = valid[i]

    for _, obj in ipairs(s.highlights or {}) do
        if (obj.valid) then
            obj.destroy()
        end
    end
    local highlights = {}
    for _, entity in ipairs(valid) do
        local box = entity.selection_box
        highlights[#highlights + 1] = rendering.draw_rectangle({
            color = HIGHLIGHT_COLOR, width = 4, filled = false,
            left_top = box.left_top, right_bottom = box.right_bottom,
            surface = entity.surface, time_to_live = HIGHLIGHT_TICKS, players = { player },
        })
        highlights[#highlights + 1] = rendering.draw_rectangle({
            color = HIGHLIGHT_COLOR, width = 64, filled = false,
            left_top = box.left_top, right_bottom = box.right_bottom,
            surface = entity.surface, time_to_live = HIGHLIGHT_TICKS, players = { player }, render_mode = "chart",
        })
    end
    s.highlights = highlights

    -- switching to the remote view closes what the player had open: keep this window
    s.ignore_close_tick = game.tick
    player.set_controller({ type = defines.controllers.remote, position = target.position, surface = target.surface })
    player.zoom = 0.5 * player.display_resolution.width / 1920
    if (not s.is_pinned and s.gui and s.gui.wnd_main.valid) then
        player.opened = s.gui.wnd_main
    end
end

flib_gui.add_handlers({
    on_detail_building_click = on_detail_building_click,
    on_detail_item_click = on_detail_item_click,
    on_detail_close_click = on_detail_close_click,
    on_detail_refresh_click = on_detail_refresh_click,
}, nil, "bce")

--- Show the report of an item under the targets (nil: close it).
---@param player LuaPlayer
---@param id string?
function gui.show_item_detail(player, id)
    local s = gui.get_storage(player)
    s.detail_item = id
    if (not s.result or not s.gui or not s.gui.wnd_main.valid) then
        return
    end
    local ui = s.gui
    ui.table_targets.clear()
    render_targets(player, s, ui, s.result)
end

--- Clickable item icon: opens that item's report.
---@param node Rates.Node
---@param id string
---@param item BCE.Item?
local function detail_item_button(node, id, item)
    local button = api.gui.gui_button(api.node.gui_default(node))
    local tip = { "" }
    -- the icon's own tooltip is often empty (the item tooltip comes from elem_tooltip)
    local function line(text)
        if (#tip > 1) then
            tip[#tip + 1] = "\n"
        end
        tip[#tip + 1] = text
    end
    if (button.tooltip and button.tooltip ~= "") then
        line(button.tooltip)
    end
    if (item and item.coverage) then
        line({ "gui.bottleneck-calc-extreme-detail-coverage", percent(item.coverage) })
    end
    line({ "gui.bottleneck-calc-extreme-detail-click-item" })
    return {
        type = "sprite-button",
        style = "flib_slot_button_default",
        style_mods = { size = 32 },
        sprite = button.sprite,
        quality = button.quality and button.quality.name,
        tooltip = tip,
        tags = { detail_id = id, bce_pipette = node_pipette(node) },
        handler = { [defines.events.on_gui_click] = on_detail_item_click },
    }
end

---@param coverage number?
local function coverage_color(coverage)
    if (not coverage) then
        return nil
    end
    if (coverage < 1 - 1e-6) then
        return percent(coverage) == "100%" and color_yellow or color_red
    end
    return coverage < 1.05 and color_yellow or color_green
end

--- What the buildings are doing right now.
---@param live BCE.Live?
---@param consumer boolean
local function live_caption(live, consumer)
    if (not live or live.total == 0) then
        return ""
    end
    local parts = { "", { "gui.bottleneck-calc-extreme-live-working", tostring(live.working), tostring(live.total) } }
    if (live.waiting_this > 0) then
        parts[#parts + 1] = ", [color=#ff6060]"
        parts[#parts + 1] = { "gui.bottleneck-calc-extreme-live-waiting-this", tostring(live.waiting_this) }
        parts[#parts + 1] = "[/color]"
    end
    local others = {}
    for icon, n in pairs(live.waiting_other) do
        others[#others + 1] = { icon = icon, n = n }
    end
    table.sort(others, function(a, b) if (a.n ~= b.n) then return a.n > b.n end return a.icon < b.icon end)
    for i, o in ipairs(others) do
        if (i > 3) then
            break
        end
        parts[#parts + 1] = ", "
        parts[#parts + 1] = { "gui.bottleneck-calc-extreme-live-waiting-for", tostring(o.n), o.icon }
    end
    if (live.output_full > 0) then
        parts[#parts + 1] = ", "
        parts[#parts + 1] = { "gui.bottleneck-calc-extreme-live-output-full", tostring(live.output_full) }
    end
    if (live.other > 0) then
        parts[#parts + 1] = ", "
        parts[#parts + 1] = { "gui.bottleneck-calc-extreme-live-other", tostring(live.other) }
    end
    -- localised strings take at most 20 parameters
    if (#parts > 20) then
        parts = { "", table.unpack(parts, 2, 20) }
    end
    return parts
end

---@param d BCE.DetailRow
local function detail_row_icons(d)
    local count = math.floor(d.have + 0.5)
    local entity = api.configuration.gui_entity(d.row.conf)
    local conf = d.row.conf
    local entity_name = conf.entity and conf.entity.name
        or (conf.children and conf.children[1].entity and conf.children[1].entity.name)
    local entity_icon = create_node_icon(entity, tostring(count), entity_name and { type = "entity", name = entity_name } or nil)
    local b = entity_icon[1]
    if (b and #(d.row.entities or {}) > 0) then
        -- a button that shows them on the map
        b.style = "flib_slot_button_default"
        b.style_mods = { size = 36 }
        b.ignored_by_interaction = false
        b.tooltip = { "", entity_icon.tooltip or b.tooltip or "", "\n",
            { "gui.bottleneck-calc-extreme-detail-jump", tostring(#d.row.entities) } }
        b.elem_tooltip = entity_icon.elem_tooltip or b.elem_tooltip
        entity_icon.tooltip, entity_icon.elem_tooltip = nil, nil
        local tags = b.tags or {}
        tags.jump_row = d.ri
        b.tags = tags
        b.handler = { [defines.events.on_gui_click] = on_detail_building_click }
    end
    return create_node_icon(api.configuration.gui_recipe(d.row.conf), nil, recipe_pipette(d.row.conf)), entity_icon
end

--- "runs" column: the plan's buildings compared to the ones you have.
---@param d BCE.DetailRow
local function runs_cell(d)
    if (not d.x or d.row.is_target) then
        return { type = "label", caption = "" }
    end
    local u = d.have > 0 and d.x / d.have or (d.x > 0 and math.huge or 0)
    local caption = u == math.huge and "—" or percent(u)
    return { type = "label", caption = caption, style_mods = { font_color = u > 1 + 1e-6 and color_red or nil },
        tooltip = { "gui.bottleneck-calc-extreme-detail-runs-tooltip" } }
end

---@param parent LuaGuiElement
---@param caption LocalisedString
local function detail_caption(parent, caption)
    flib_gui.add(parent, { type = "label", caption = caption, style = "bold_label", style_mods = { top_margin = 6 } })
end

---@param parent LuaGuiElement
---@param headers LocalisedString[]
local function detail_table(parent, headers)
    local tbl = parent.add({ type = "table", column_count = #headers })
    tbl.style.horizontal_spacing = 8
    tbl.style.vertical_spacing = 0
    local row = {}
    for i, h in ipairs(headers) do
        row[i] = { type = "label", caption = h, style_mods = { font_color = color_grey } }
    end
    flib_gui.add(tbl, row)
    return tbl
end

---@param parent LuaGuiElement
---@param s BCE.PlayerStorage
---@param result BCE.Result
render_detail = function(parent, s, result)
    if (not s.detail_item or not s.scan) then
        return
    end
    local d = detail.build(s.scan, result, s.detail_item)
    if (not d) then
        return
    end
    local items = {} ---@type table<string, BCE.Item>
    for _, e in ipairs(result.items) do
        items[e.id] = e
    end
    local ui = api.node.gui_default(d.node)
    local function amt(x)
        return api.gui.gui_amount_text(ui, x)
    end

    flib_gui.add(parent, {
        type = "flow",
        direction = "horizontal",
        style_mods = { vertical_align = "center", top_margin = 12 },
        header_def({ "gui.bottleneck-calc-extreme-detail-title" }, "detail"),
        { type = "empty-widget", style = "flib_horizontal_pusher" },
        {
            type = "sprite-button",
            style = "tool_button",
            sprite = "utility/refresh",
            tooltip = { "gui.bottleneck-calc-extreme-detail-refresh" },
            handler = { [defines.events.on_gui_click] = on_detail_refresh_click },
        },
        {
            type = "sprite-button",
            style = "tool_button_red",
            sprite = "utility/close",
            tooltip = { "gui.bottleneck-calc-extreme-detail-close" },
            handler = { [defines.events.on_gui_click] = on_detail_close_click },
        },
    })
    local item = d.item
    local summary = { type = "flow", direction = "horizontal", style_mods = { vertical_align = "center" },
        detail_item_button(d.node, d.id, item),
        { type = "label", caption = api.gui.gui_button_and_text(ui, nil).text, style = "bold_label", style_mods = { left_margin = 4 } } }
    if (item) then
        if (not s.is_pinned) then
            summary[#summary + 1] = { type = "label", style_mods = { left_margin = 12 },
                caption = { "gui.bottleneck-calc-extreme-detail-summary", amt(item.needed), amt(item.capacity) } }
        end
        summary[#summary + 1] = { type = "label", caption = difference_caption(item.capacity, item.needed, amt),
            style_mods = { left_margin = 8 } }
    end
    flib_gui.add(parent, summary)
    local compact = s.is_pinned == true

    -- where it goes
    detail_caption(parent, { "gui.bottleneck-calc-extreme-detail-goes-to" })
    if (#d.consumers == 0) then
        flib_gui.add(parent, { type = "label", caption = { "gui.bottleneck-calc-extreme-detail-no-consumers" } })
    else
        local headers = { "", "", { "gui.bottleneck-calc-extreme-detail-col-uses" },
            { "gui.bottleneck-calc-extreme-detail-col-runs" }, { "gui.bottleneck-calc-extreme-detail-col-for" } }
        if (not compact) then
            headers[#headers + 1] = { "gui.bottleneck-calc-extreme-detail-col-now" }
        end
        local tbl = detail_table(parent, headers)
        tbl.style.column_alignments[3] = "right"
        tbl.style.column_alignments[4] = "right"
        for i, c in ipairs(d.consumers) do
            if (i > DETAIL_ROWS) then
                flib_gui.add(parent, { type = "label", caption = { "gui.bottleneck-calc-extreme-more", tostring(#d.consumers - DETAIL_ROWS) } })
                break
            end
            local recipe_icon, entity_icon = detail_row_icons(c)
            local uses
            if (c.x) then
                uses = { type = "label", caption = amt(c.rate) }
            else
                uses = { type = "label", caption = { "gui.bottleneck-calc-extreme-detail-not-for-targets" },
                    style_mods = { font_color = color_grey },
                    tooltip = { "gui.bottleneck-calc-extreme-detail-not-for-targets-tooltip", amt(c.per_building * c.have) } }
            end
            local makes = { type = "flow", style = "packed_horizontal_flow", style_mods = { vertical_align = "center" } }
            local hidden = 0
            for _, id in ipairs(c.products or {}) do
                local e = items[id]
                if (compact and not (e.coverage and e.coverage < 1 - 1e-6)) then
                    -- compact: only the short ones, the covered ones as a count
                    hidden = hidden + 1
                elseif (#makes >= 6) then
                    hidden = hidden + 1
                else
                    makes[#makes + 1] = detail_item_button(e.node, id, e)
                    makes[#makes + 1] = { type = "label", caption = e.coverage and percent(e.coverage) or "",
                        style_mods = { font_color = coverage_color(e.coverage), left_margin = 2, right_margin = 6 } }
                end
            end
            if (hidden > 0) then
                makes[#makes + 1] = { type = "label", caption = compact and ("(+" .. hidden .. ")") or "…" }
            end
            local cells = { recipe_icon, entity_icon, uses, runs_cell(c), makes }
            if (not compact) then
                cells[#cells + 1] = { type = "label", caption = live_caption(c.live, true) }
            end
            flib_gui.add(tbl, cells)
        end
    end

    -- where it comes from
    detail_caption(parent, { "gui.bottleneck-calc-extreme-detail-made-by" })
    if (#d.producers == 0) then
        flib_gui.add(parent, { type = "label", caption = { "gui.bottleneck-calc-extreme-detail-no-producers" } })
    else
        local tbl
        if (compact) then
            tbl = detail_table(parent, { "", "", { "gui.bottleneck-calc-extreme-col-difference" },
                { "gui.bottleneck-calc-extreme-detail-col-runs" }, { "gui.bottleneck-calc-extreme-detail-col-short-inputs" } })
            for c = 3, 4 do
                tbl.style.column_alignments[c] = "right"
            end
        else
            tbl = detail_table(parent, { "", "", { "gui.bottleneck-calc-extreme-col-can-make" },
                { "gui.bottleneck-calc-extreme-detail-col-makes" }, { "gui.bottleneck-calc-extreme-detail-col-runs" },
                { "gui.bottleneck-calc-extreme-detail-col-also" }, { "gui.bottleneck-calc-extreme-detail-col-short-inputs" },
                { "gui.bottleneck-calc-extreme-detail-col-now" } })
            for c = 3, 5 do
                tbl.style.column_alignments[c] = "right"
            end
        end
        for i, p in ipairs(d.producers) do
            if (i > DETAIL_ROWS) then
                flib_gui.add(parent, { type = "label", caption = { "gui.bottleneck-calc-extreme-more", tostring(#d.producers - DETAIL_ROWS) } })
                break
            end
            local recipe_icon, entity_icon = detail_row_icons(p)
            local also = { type = "flow", style = "packed_horizontal_flow", style_mods = { vertical_align = "center" } }
            for k, id in ipairs(p.byproducts or {}) do
                if (k > 4) then
                    also[#also + 1] = { type = "label", caption = "…" }
                    break
                end
                also[#also + 1] = detail_item_button(items[id].node, id, items[id])
            end
            local short = { type = "flow", style = "packed_horizontal_flow", style_mods = { vertical_align = "center" } }
            local short_list = {}
            for _, id in ipairs(p.short_inputs or {}) do
                short_list[#short_list + 1] = items[id]
            end
            table.sort(short_list, function(a, b) return a.coverage < b.coverage end)
            for k, e in ipairs(short_list) do
                if (k > 3) then
                    short[#short + 1] = { type = "label", caption = "…" }
                    break
                end
                short[#short + 1] = detail_item_button(e.node, e.id, e)
                short[#short + 1] = { type = "label", caption = percent(e.coverage),
                    style_mods = { font_color = coverage_color(e.coverage), left_margin = 2, right_margin = 6 } }
            end
            if (compact) then
                flib_gui.add(tbl, {
                    recipe_icon, entity_icon,
                    { type = "label", caption = p.x and difference_caption(p.per_building * p.have, p.rate, amt) or "",
                        tooltip = not p.x and { "gui.bottleneck-calc-extreme-detail-not-for-targets-tooltip-made" } or nil },
                    runs_cell(p),
                    short,
                })
            else flib_gui.add(tbl, {
                recipe_icon, entity_icon,
                { type = "label", caption = amt(p.per_building * p.have) },
                { type = "label", caption = p.x and amt(p.rate) or "",
                    tooltip = not p.x and { "gui.bottleneck-calc-extreme-detail-not-for-targets-tooltip-made" } or nil },
                runs_cell(p),
                also,
                short,
                { type = "label", caption = live_caption(p.live, false) },
            }) end
        end
    end

    -- on to the targets
    if (#d.path > 0) then
        detail_caption(parent, { "gui.bottleneck-calc-extreme-detail-path" })
        local flow = { type = "flow", direction = "horizontal", style_mods = { vertical_align = "top", horizontal_spacing = 2 } }
        --- Every step is a 32 px icon over a small label, so arrows and the target get an empty
        --- label under them too and line up with the item buttons.
        local function column(top, caption, color)
            return {
                type = "flow", direction = "vertical", style_mods = { horizontal_align = "center", vertical_spacing = 0 },
                top,
                { type = "label", caption = caption, style_mods = { font = "default-small-semibold", font_color = color } },
            }
        end
        local function add_step(e)
            flow[#flow + 1] = column(detail_item_button(e.node, e.id, e), e.coverage and percent(e.coverage) or " ",
                coverage_color(e.coverage))
        end
        if (item) then
            add_step(item)
        end
        for _, step in ipairs(d.path) do
            flow[#flow + 1] = column({ type = "label", caption = "→",
                style_mods = { font = "default-large", height = 32, vertical_align = "center" } }, " ")
            if (step.id) then
                if (#flow > 36) then
                    flow[#flow] = column({ type = "label", caption = "…",
                        style_mods = { height = 32, vertical_align = "center" } }, " ")
                    break
                end
                add_step(items[step.id])
            elseif (step.row) then
                local icon = create_node_icon(api.configuration.gui_recipe(step.row.conf), nil, recipe_pipette(step.row.conf))
                if (icon[1]) then
                    icon[1].style_mods = { size = 32 }
                end
                flow[#flow + 1] = column(icon, " ")
            end
        end
        local wrap = parent.add({ type = "scroll-pane", horizontal_scroll_policy = "auto", vertical_scroll_policy = "never" })
        -- scrolls rather than widening the window; narrower still in the compact view
        wrap.style.maximal_width = compact and 360 or 640
        flib_gui.add(wrap, flow)
    end
end

---@param player LuaPlayer
---@param s BCE.PlayerStorage
---@param ui BCE.GuiElements
---@param result BCE.Result
render_targets = function(player, s, ui, result)
    -- targets and their speeds
    local tf = ui.table_targets
    flib_gui.add(tf, header_def({ "gui.bottleneck-calc-extreme-targets" }, "targets"))
    local tb = tf.add({ type = "table", column_count = 5 })
    tb.style.vertical_spacing = 0
    tb.style.column_alignments[1] = "right"
    local targets = {}
    for _, t in ipairs(result.targets) do
        targets[#targets + 1] = t
    end
    table.sort(targets, function(a, b) return a.row.key < b.row.key end)
    local compact = s.is_pinned == true
    local pending = s.pending_speeds or {}
    for _, t in ipairs(targets) do
        local speed_cell
        if (compact) then
            -- no slider: the speed the numbers were worked out for
            speed_cell = cell_speed(t.row, s.speeds[t.row.key] or 1, false)
            table.remove(speed_cell, 1)
        else
            speed_cell = cell_speed(t.row, pending[t.row.key] or s.speeds[t.row.key] or 1, pending[t.row.key] ~= nil)
        end
        flib_gui.add(tb, {
            { type = "label", caption = tostring(t.row.count_max) .. " × ", style_mods = { font = "item-count" } },
            cell_annotations(t.row),
            create_node_icon(api.configuration.gui_recipe(t.row.conf), nil, recipe_pipette(t.row.conf)),
            cell_entity(t.row, #targets > 1),
            speed_cell,
        })
    end
    if (not compact) then flib_gui.add(tf, {
        type = "flow",
        name = "bce_apply_flow",
        -- shown once a slider moves; after the answer is worked out it would only be clutter
        visible = s.pending_speeds ~= nil,
        style_mods = { horizontal_align = "right", horizontally_stretchable = true, top_margin = 4 },
        {
            type = "button",
            name = "bce_apply_speeds",
            caption = { "gui.bottleneck-calc-extreme-apply-speeds" },
            tooltip = { "gui.bottleneck-calc-extreme-apply-speeds-tooltip" },
            enabled = s.pending_speeds ~= nil,
            handler = { [defines.events.on_gui_click] = on_apply_speeds_click },
        },
    }) end


    render_detail(ui.table_targets, s, result)
end

---@param player LuaPlayer
---@param result BCE.Result
function gui.render(player, result)
    local s = gui.get_storage(player)
    local ui = gui.build(player)
    local compact = s.is_pinned == true
    if (ui.table_items) then
        ui.table_items.clear()
    end
    ui.table_targets.clear()
    local max_rows = settings.get_player_settings(player)["bottleneck-calc-extreme-max-rows"].value --[[@as integer]]

    local short, enough, inputs, unlimited = {}, {}, {}, {}
    for _, e in ipairs(result.items) do
        if (e.needed < FLOW_TOL) then
            -- only made (a byproduct nothing here uses), or solver noise
        elseif (e.mode == "ignored") then
            unlimited[#unlimited + 1] = e
        elseif (e.mode == "free") then
            inputs[#inputs + 1] = e
        elseif (e.coverage < 1 - 1e-6) then
            short[#short + 1] = e
        else
            enough[#enough + 1] = e
        end
    end
    local function by_coverage(a, b)
        if (a.coverage ~= b.coverage) then return a.coverage < b.coverage end
        return a.id < b.id
    end
    table.sort(short, by_coverage)
    table.sort(enough, by_coverage)
    local function by_type_then_amount(a, b)
        local ta, tb = node_type(a.node), node_type(b.node)
        if (ta ~= tb) then return ta < tb end
        if (a.needed ~= b.needed) then return a.needed > b.needed end
        return a.id < b.id
    end
    table.sort(inputs, by_type_then_amount)
    table.sort(unlimited, by_type_then_amount)

    ui.label_status.caption = status_caption(result, short, compact)

    render_targets(player, s, ui, result)

    local ti = ui.table_items
    if (not ti) then
        return
    end
    item_section(ti, { "gui.bottleneck-calc-extreme-short", tostring(#short) }, "short", short, max_rows, "short", compact)
    item_section(ti, { "gui.bottleneck-calc-extreme-enough", tostring(#enough) }, "enough", enough, max_rows, "enough", compact)
    item_section(ti, { "gui.bottleneck-calc-extreme-inputs" }, "inputs", inputs, max_rows, "used", compact)
    item_section(ti, { "gui.bottleneck-calc-extreme-unlimited" }, "unlimited", unlimited, max_rows, "used", compact)
end

return gui
