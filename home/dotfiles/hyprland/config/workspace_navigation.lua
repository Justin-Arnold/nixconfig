local displays = require("hyprland.data.displays")
local keybindings = require("hyprland.data.keybindings")
local hy3 = assert(hl.plugin.hy3, "hy3 plugin is not loaded")

local groups = {
    { name = "center", monitor = displays.center.desc, workspaces = { 1, 2, 3 } },
    { name = "left", monitor = displays.left.desc, workspaces = { 4, 5, 6 } },
    { name = "right", monitor = displays.right.desc, workspaces = { 7, 8, 9 } },
}

local main_mod = keybindings.main_mod
local move_mod = main_mod .. " + CTRL"
local tap_mode = true
local pending

local function focus(workspace)
    return hl.dispatch(hl.dsp.focus({ workspace = workspace }))
end

local function select_workspace(group, move)
    if not tap_mode and not move then
        pending = nil
        return focus(group.workspaces[1])
    end

    if tap_mode and pending and pending.group == group and pending.move == move then
        pending.slot = math.min(pending.slot + 1, #group.workspaces)
        return
    end

    local window = move and hl.get_active_window()
    pending = {
        group = group,
        slot = 1,
        move = move,
        window_id = window and window.stable_id,
    }
end

for key, group in ipairs(groups) do
    hl.bind(main_mod .. " + " .. key, function()
        return select_workspace(group, false)
    end, { description = "Go to workspace group (" .. group.name .. ")" })
    hl.bind(move_mod .. " + " .. key, function()
        select_workspace(group, true)
    end, { description = "Send window to workspace group (" .. group.name .. ")" })
end

hl.bind(main_mod .. " + Tab", function()
    if not tap_mode then
        local monitor = hl.get_active_monitor()
        local active = monitor and monitor.active_workspace
        for _, group in ipairs(groups) do
            if monitor and group.monitor == "desc:" .. monitor.description then
                for slot, workspace in ipairs(group.workspaces) do
                    if active and active.id == workspace then
                        return focus(group.workspaces[slot % #group.workspaces + 1])
                    end
                end
                return focus(group.workspaces[1])
            end
        end
    end
    return { pass_event = true }
end, { description = "Next workspace in group (Tab mode)" })

hl.bind(move_mod .. " + Tab", function()
    if tap_mode or not pending then
        return { pass_event = true }
    end
    pending.slot = pending.slot % #pending.group.workspaces + 1
end, { description = "Next workspace to send to (Tab mode)" })

-- Modifier-only release binds skip keys used in a chord. The keyboard event
-- also sees those releases and reports XKB keycodes (9 = Escape, 133/134 = Super).
hl.on("input.keyboard.key", function(keycode, _, state)
    if not pending then
        return
    end
    if keycode == 9 and state == 1 then
        pending = nil
        return
    end
    if state ~= 0 or (keycode ~= 133 and keycode ~= 134) then
        return
    end

    local selection = pending
    pending = nil
    local workspace = selection.group.workspaces[selection.slot]
    if selection.move then
        local window = hl.get_active_window()
        if window and window.stable_id == selection.window_id then
            hl.dispatch(hy3.move_to_workspace(tostring(workspace), { follow = false }))
        end
    else
        focus(workspace)
    end
end)

hl.bind(main_mod .. " + F12", function()
    tap_mode = not tap_mode
    pending = nil
    hl.notification.create({
        text = tap_mode and "Workspace tap mode" or "Workspace Tab mode",
        icon = "info",
        timeout = 2000,
    })
end, { description = "Switch workspace tap or Tab mode" })

return groups
