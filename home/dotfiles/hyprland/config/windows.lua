local keybindings = require("hyprland.data.keybindings")
local resize_amount = 50

local hy3 = assert(
    hl.plugin.hy3,
    "hy3 plugin is not loaded"
)


-- Resize active window with main_mod + CTRL + hjkl
hl.bind(
    keybindings.main_mod .. " + CTRL + H",
    hl.dsp.window.resize({
        x = -resize_amount,
        y = 0,
        relative = true
    }),
    { repeating = true, description = "Resize window (narrower)" }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + L",
    hl.dsp.window.resize({
        x = resize_amount,
        y = 0,
        relative = true
    }),
    { repeating = true, description = "Resize window (wider)" }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + K",
    hl.dsp.window.resize({
        x = 0,
        y = -resize_amount,
        relative = true
    }),
    { repeating = true, description = "Resize window (shorter)" }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + J",
    hl.dsp.window.resize({
        x = 0,
        y = resize_amount,
        relative = true
    }),
    { repeating = true, description = "Resize window (taller)" }
)


-- Move focus between windows with main_mod + hjkl
hl.bind(
    keybindings.main_mod .. " + H",
    hy3.move_focus("l"),
    { description = "Focus window (left)" }
)

hl.bind(
    keybindings.main_mod .. " + L",
    hy3.move_focus("r"),
    { description = "Focus window (right)" }
)

hl.bind(
    keybindings.main_mod .. " + K",
    hy3.move_focus("u"),
    { description = "Focus window (up)" }
)

hl.bind(
    keybindings.main_mod .. " + J",
    hy3.move_focus("d"),
    { description = "Focus window (down)" }
)


-- Move/reparent active window with main_mod + SHIFT + hjkl
hl.bind(
    keybindings.main_mod .. " + SHIFT + H",
    hy3.move_window("l", { once = true, visible = true }),
    { description = "Move window (left)" }
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + L",
    hy3.move_window("r", { once = true, visible = true }),
    { description = "Move window (right)" }
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + K",
    hy3.move_window("u", { once = true, visible = true }),
    { description = "Move window (up)" }
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + J",
    hy3.move_window("d", { once = true, visible = true }),
    { description = "Move window (down)" }
)