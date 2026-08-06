-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- Or execute your favorite apps at launch like this:

local session_environment =
    "PATH WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP " ..
    "DESKTOP_SESSION XDG_SESSION_TYPE XDG_CONFIG_DIRS XDG_DATA_DIRS " ..
    "XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS"

hl.on("hyprland.start", function()
    hl.exec_cmd(
        "sh -c 'systemctl --user import-environment " .. session_environment .. " || true; " ..
        "dbus-update-activation-environment --systemd " .. session_environment .. " || true; " ..
        "systemctl --user start graphical-session.target; " ..
        "systemctl --user restart hyprpaper.service'"
    )
end)
