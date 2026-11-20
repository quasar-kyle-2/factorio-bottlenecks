local type_filters = {
    "agricultural-tower",
    "assembling-machine",
    "asteroid-collector",
    "boiler",
    "burner-generator",
    "furnace",
    "fusion-generator",
    "fusion-reactor",
    "generator",
    "lab",
    "mining-drill",
    "offshore-pump",
    "reactor",
    "rocket-silo",
    "thruster",
}

local function selection(color)
    return {
        border_color = color,
        cursor_box_type = "entity",
        mode = { "buildable-type", "friend", "entity-ghost" },
        entity_type_filters = type_filters,
    }
end

---@type data.SelectionToolPrototype
local tool = {
    type = "selection-tool",
    name = "bottleneck-calc-extreme-tool",
    -- drag adds targets, right-drag removes them (shift does the same, so it never surprises)
    select = selection({ g = 1 }),
    alt_select = selection({ g = 1 }),
    reverse_select = selection({ r = 1 }),
    alt_reverse_select = selection({ r = 1 }),
    stack_size = 1,
    flags = { "only-in-cursor", "spawnable", "not-stackable" },
    hidden = true,
    icon = "__bottleneck-calc-extreme__/graphics/tool-x32.png",
    icon_size = 32,
}

---@type data.ShortcutPrototype
local shortcut = {
    type = "shortcut",
    name = "bottleneck-calc-extreme-shortcut",
    -- opens (or closes) the window as it was left; the selection tool is picked up from there
    action = "lua",
    icon = "__bottleneck-calc-extreme__/graphics/tool-x32.png",
    small_icon = "__bottleneck-calc-extreme__/graphics/tool-x24.png",
    icon_size = 32,
    small_icon_size = 24,
}

---@type data.CustomInputPrototype
local custom_input = {
    type = "custom-input",
    name = "bottleneck-calc-extreme-custom-input",
    key_sequence = "ALT + B",
}

-- White refresh icon for the dark title bar: first frame of the core refresh animation
-- (core only ships the white version as an animation, which a sprite button can't show).
---@type data.SpritePrototype
local refresh_white = {
    type = "sprite",
    name = "bottleneck-calc-extreme-refresh-white",
    filename = "__core__/graphics/refresh-white-animation.png",
    size = 32,
    position = { 0, 0 },
    scale = 0.5,
    flags = { "gui-icon" },
}

-- Follows the player's pipette binding; pipettes items and buildings shown in the window.
---@type data.CustomInputPrototype
local pipette = {
    type = "custom-input",
    name = "bottleneck-calc-extreme-pipette",
    linked_game_control = "pipette",
    key_sequence = "",
}

data:extend({ tool, shortcut, custom_input, refresh_white, pipette })

