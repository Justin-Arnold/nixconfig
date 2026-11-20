-- https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/

local keybindings = require("hyprland.data.keybindings")
local groups = require("hyprland.config.workspace_navigation")

for _, group in ipairs(groups) do
    for slot, workspace in ipairs(group.workspaces) do
        hl.workspace_rule({
            workspace = tostring(workspace),
            monitor = group.monitor,
            default = slot == 1 or nil,
        })
    end
end


-- Floating Workspace
hl.bind(
    keybindings.main_mod .. " + F",
    hl.dsp.workspace.toggle_special("magic")
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + F",
    hl.dsp.window.move({ workspace = "special:magic" })
)
