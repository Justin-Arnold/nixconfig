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
    { repeating = true }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + L",
    hl.dsp.window.resize({
        x = resize_amount,
        y = 0,
        relative = true
    }),
    { repeating = true }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + K",
    hl.dsp.window.resize({
        x = 0,
        y = -resize_amount,
        relative = true
    }),
    { repeating = true }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + J",
    hl.dsp.window.resize({
        x = 0,
        y = resize_amount,
        relative = true
    }),
    { repeating = true }
)


-- Move focus between windows with main_mod + hjkl
hl.bind(
    keybindings.main_mod .. " + H",
    hy3.move_focus("l")
)

hl.bind(
    keybindings.main_mod .. " + L",
    hy3.move_focus("r")
)

hl.bind(
    keybindings.main_mod .. " + K",
    hy3.move_focus("u")
)

hl.bind(
    keybindings.main_mod .. " + J",
    hy3.move_focus("d")
)


-- Move/reparent active window with main_mod + SHIFT + hjkl
hl.bind(
    keybindings.main_mod .. " + SHIFT + H",
    hy3.move_window("l", { once = true, visible = true })
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + L",
    hy3.move_window("r", { once = true, visible = true })
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + K",
    hy3.move_window("u", { once = true, visible = true })
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + J",
    hy3.move_window("d", { once = true, visible = true })
)