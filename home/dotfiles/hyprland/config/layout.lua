local colors = require("hyprland.data.colors")
local keybindings = require("hyprland.data.keybindings")
local hy3 = assert(hl.plugin.hy3, "hy3 plugin is not loaded")

-- A palette role (data/colors.lua) at an opacity, as hex: "ff" is opaque.
local function rgba(role, alpha)
    return "rgba(" .. colors[role] .. alpha .. ")"
end

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

            -- Tab bars in the theme's colors: a tinted fill, a border and
            -- the title per state. Translucent fills are blurred.
            tabs = {
                colors = {
                    -- The focused tab
                    active        = rgba("accent", "40"),
                    active_border = rgba("accent", "ee"),
                    active_text   = rgba("fg", "ff"),

                    -- The focused tab, on a monitor without focus
                    active_alt_monitor        = rgba("selection", "80"),
                    active_alt_monitor_border = rgba("border-strong", "ee"),
                    active_alt_monitor_text   = rgba("fg", "ff"),

                    -- The tab with focus inside a group that doesn't have it
                    focused        = rgba("selection", "80"),
                    focused_border = rgba("border-strong", "ee"),
                    focused_text   = rgba("fg", "ff"),

                    -- Every other tab, the same border as unfocused windows
                    inactive        = rgba("surface", "80"),
                    inactive_border = rgba("border", "aa"),
                    inactive_text   = rgba("fg-muted", "ff"),

                    urgent        = rgba("red", "40"),
                    urgent_border = rgba("red", "ee"),
                    urgent_text   = rgba("fg", "ff"),

                    locked        = rgba("yellow", "40"),
                    locked_border = rgba("yellow", "ee"),
                    locked_text   = rgba("fg", "ff"),
                },
            },
        },
    },
})

hl.bind(
    keybindings.main_mod .. " + P",
    hy3.change_group("opposite"),
    { description = "Flip split direction" }
)