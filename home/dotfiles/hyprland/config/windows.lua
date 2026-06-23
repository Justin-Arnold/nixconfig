local keybindings = require("hyprland.data.keybindings")
local resize_amount = 50

-- Resize active window with main_mod + CTRL + hjkl
hl.bind(
    keybindings.main_mod .. " + CTRL + H",
    hl.dsp.window.resize({ x = -resize_amount, y = 0, relative = true }),
    { repeating = true }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + L",
    hl.dsp.window.resize({ x = resize_amount, y = 0, relative = true }),
    { repeating = true }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + K",
    hl.dsp.window.resize({ x = 0, y = -resize_amount, relative = true }),
    { repeating = true }
)

hl.bind(
    keybindings.main_mod .. " + CTRL + J",
    hl.dsp.window.resize({ x = 0, y = resize_amount, relative = true }),
    { repeating = true }
)

-- Move focus between windows with main_mod + hjkl
hl.bind(keybindings.main_mod .. " + H", hl.dsp.focus({ direction = "left" }))
hl.bind(keybindings.main_mod .. " + L", hl.dsp.focus({ direction = "right" }))
hl.bind(keybindings.main_mod .. " + K", hl.dsp.focus({ direction = "up" }))
hl.bind(keybindings.main_mod .. " + J", hl.dsp.focus({ direction = "down" }))

-- Swap active window with neighboring window with main_mod + hjkl
hl.bind(keybindings.main_mod .. " + SHIFT + H", hl.dsp.window.swap({ direction = "left" }))
hl.bind(keybindings.main_mod .. " + SHIFT + L", hl.dsp.window.swap({ direction = "right" }))
hl.bind(keybindings.main_mod .. " + SHIFT + K", hl.dsp.window.swap({ direction = "up" }))
hl.bind(keybindings.main_mod .. " + SHIFT + J", hl.dsp.window.swap({ direction = "down" }))