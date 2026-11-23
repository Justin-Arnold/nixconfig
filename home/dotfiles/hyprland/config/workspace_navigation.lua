local displays = require("hyprland.data.displays")
local keybindings = require("hyprland.data.keybindings")
local hy3 = assert(hl.plugin.hy3, "hy3 plugin is not loaded")

local groups = {
    { name = "center", monitor = displays.center.desc, workspaces = { 1, 2, 3 } },
    { name = "left", monitor = displays.left.desc, workspaces = { 4, 5, 6 } },
    { name = "right", monitor = displays.right.desc, workspaces = { 7, 8, 9 } },
}

-- Three special workspaces on one key, picked the same way: tap the key
-- once, twice or three times, then let go of Super. Picking the one that is
-- showing hides it.
local floating = {
    name = "floating",
    special = true,
    workspaces = { "floating-1", "floating-2", "floating-3" },
}

local main_mod = keybindings.main_mod
local move_mod = main_mod .. " + SHIFT"
local tap_mode = true
local pending

local function focus(group, workspace)
    if group.special then
        return hl.dispatch(hl.dsp.workspace.toggle_special(workspace))
    end
    return hl.dispatch(hl.dsp.focus({ workspace = workspace }))
end

local function move(group, workspace)
    if group.special then
        return hl.dispatch(hl.dsp.window.move({ workspace = "special:" .. workspace }))
    end
    return hl.dispatch(hy3.move_to_workspace(tostring(workspace), { follow = false }))
end

local function select_workspace(group, moving)
    if not tap_mode and not moving then
        pending = nil
        return focus(group, group.workspaces[1])
    end

    if tap_mode and pending and pending.group == group and pending.move == moving then
        pending.slot = math.min(pending.slot + 1, #group.workspaces)
        return
    end

    local window = moving and hl.get_active_window()
    pending = {
        group = group,
        slot = 1,
        move = moving,
        window_id = window and window.stable_id,
    }
end

local function bind_group(key, group, go, send)
    hl.bind(main_mod .. " + " .. key, function()
        return select_workspace(group, false)
    end, { description = go })
    hl.bind(move_mod .. " + " .. key, function()
        select_workspace(group, true)
    end, { description = send })
end

for key, group in ipairs(groups) do
    bind_group(key, group,
        "Go to workspace group (" .. group.name .. ")",
        "Send window to workspace group (" .. group.name .. ")")
end
bind_group(0, floating, "Toggle floating workspace", "Move window to floating workspace")

-- The floating workspace showing on the focused monitor, as its slot.
local function shown_floating()
    local special = hl.get_active_special_workspace()
    if not special then
        return nil
    end
    for slot, name in ipairs(floating.workspaces) do
        if special.name == "special:" .. name or special.name == name then
            return slot
        end
    end
end

hl.bind(main_mod .. " + Tab", function()
    if not tap_mode then
        local slot = shown_floating()
        if slot then
            return focus(floating, floating.workspaces[slot % #floating.workspaces + 1])
        end

        local monitor = hl.get_active_monitor()
        local active = monitor and monitor.active_workspace
        for _, group in ipairs(groups) do
            if monitor and group.monitor == "desc:" .. monitor.description then
                for slot, workspace in ipairs(group.workspaces) do
                    if active and active.id == workspace then
                        return focus(group, group.workspaces[slot % #group.workspaces + 1])
                    end
                end
                return focus(group, group.workspaces[1])
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
            move(selection.group, workspace)
        end
    else
        focus(selection.group, workspace)
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
