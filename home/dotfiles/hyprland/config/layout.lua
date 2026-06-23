local keybindings = require("hyprland.data.keybindings")

hl.config({
    general = {
        layout = "dwindle",
    }
})

-- See https://wiki.hypr.land/Configuring/Layouts/Dwindle-Layout/ for more
hl.config({
    dwindle = {
        preserve_split = true,
    },
})

-- Toggle Dwindle split direction for the active window
hl.bind(
    keybindings.main_mod .. " + P",
    hl.dsp.layout("togglesplit")
)
