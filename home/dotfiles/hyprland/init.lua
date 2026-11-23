-- https://wiki.hypr.land/Configuring/Start/

local applications = require("hyprland.data.applications")
local colors = require("hyprland.data.colors")
local keybindings = require("hyprland.data.keybindings")

-- First, so it records every bind made after it.
require("hyprland.config.hotkeys")

require("hyprland.config.popout")
require("hyprland.config.scenes")
require("hyprland.config.animation")
require("hyprland.config.autostart")
require("hyprland.config.decoration")
require("hyprland.config.input")
require("hyprland.config.layout")
require("hyprland.config.media")
require("hyprland.config.monitors")
require("hyprland.config.utilities")
require("hyprland.config.windows")
require("hyprland.config.workspace")

hl.config({
    general = {
        gaps_in  = 5,
        gaps_out = { top = 0, right = 20, bottom = 20, left = 20 },

        border_size = 2,

        -- The theme's accent for the focused window, its border color for
        -- the rest (data/colors.lua, generated from the palette).
        col = {
            active_border   = "rgba(" .. colors.accent .. "ee)",
            inactive_border = "rgba(" .. colors.border .. "aa)",
        },

        resize_on_border = false,
        allow_tearing = false,
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
    },
})

-- Launch terminal
hl.bind(
    keybindings.main_mod .. " + T",
    hl.dsp.exec_cmd(applications.terminal),
    { description = "Open terminal" }
)

-- Open the application launcher
hl.bind(
    keybindings.main_mod .. " + Space",
    hl.dsp.exec_cmd(applications.menu),
    { description = "Open launcher" }
)

-- Close active window
hl.bind(
    keybindings.main_mod .. " + Q",
    hl.dsp.window.close(),
    { description = "Close window" }
)

-- Toggle floating
hl.bind(
    keybindings.main_mod .. " + V",
    hl.dsp.window.float({ action = "toggle" }),
    { description = "Toggle floating" }
)
