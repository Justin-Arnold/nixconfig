-- https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/

local displays = require("hyprland.data.displays")
local keybindings = require("hyprland.data.keybindings")

-- Center Monitor
hl.workspace_rule({
    workspace = "1",
    monitor = displays.center.desc,
    default = true,
})

hl.workspace_rule({
    workspace = "4",
    monitor = displays.center.desc,
})

hl.workspace_rule({
    workspace = "7",
    monitor = displays.center.desc,
})

-- Left Monitor
hl.workspace_rule({
    workspace = "2",
    monitor = displays.left.desc,
    default = true,
})

hl.workspace_rule({
    workspace = "5",
    monitor = displays.left.desc,
})

hl.workspace_rule({
    workspace = "8",
    monitor = displays.left.desc,
})

-- Right Monitor
hl.workspace_rule({
    workspace = "3",
    monitor = displays.right.desc,
    default = true,
})

hl.workspace_rule({
    workspace = "6",
    monitor = displays.right.desc,
})

hl.workspace_rule({
    workspace = "9",
    monitor = displays.right.desc,
})

---------------------
---- KEYBINDINGS ----
---------------------

-- Switch workspaces with mainMod + [0-9]
-- Move active window to a workspace with mainMod + SHIFT + [0-9]
for i = 1, 10 do
    local key = i % 10 -- 10 maps to key 0
    hl.bind(keybindings.main_mod .. " + " .. key,             hl.dsp.focus({ workspace = i}))
    hl.bind(keybindings.main_mod .. " + SHIFT + " .. key,     hl.dsp.window.move({ workspace = i }))
end

-- Floating Workspace
hl.bind(keybindings.main_mod .. " + F",         hl.dsp.workspace.toggle_special("magic"))
hl.bind(keybindings.main_mod .. " + SHIFT + F", hl.dsp.window.move({ workspace = "special:magic" }))
