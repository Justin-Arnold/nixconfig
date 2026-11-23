-- https://wiki.hypr.land/Configuring/Basics/Workspace-Rules/

-- The floating workspaces, on Super + 0, are in workspace_navigation.lua.
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
