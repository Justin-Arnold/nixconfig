local keybindings = require("hyprland.data.keybindings")
local hy3 = assert(hl.plugin.hy3, "hy3 plugin is not loaded")

hl.config({
    general = {
        layout = "hy3",
    },

    plugin = {
        hy3 = {
            autotile = {
                enable = true,

                -- Create a vertical split rather than letting
                -- a window get narrower than this.
                trigger_width = 800,

                -- Create a horizontal split rather than letting
                -- a window get shorter than this.
                trigger_height = 500,
            },
        },
    },
})

hl.bind(
    keybindings.main_mod .. " + P",
    hy3.change_group("opposite")
)