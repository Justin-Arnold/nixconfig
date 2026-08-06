-- https://wiki.hypr.land/Configuring/Start/

local applications = require("hyprland.data.applications")
local keybindings = require("hyprland.data.keybindings")

require("hyprland.config.popout")
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

        col = {
            active_border   = { colors = {"rgba(33ccffee)", "rgba(00ff99ee)"}, angle = 45 },
            inactive_border = "rgba(595959aa)",
        },

        resize_on_border = false,

        allow_tearing = false,

        layout = "dwindle",
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
    },
})

-- Launch terminal
hl.bind(
    keybindings.main_mod .. " + T",
    hl.dsp.exec_cmd(applications.terminal)
)

-- Close active window
hl.bind(
    keybindings.main_mod .. " + Q",
    hl.dsp.window.close()
)

-- Toggle floating
hl.bind(
    keybindings.main_mod .. " + V",
    hl.dsp.window.float({ action = "toggle" })
)
