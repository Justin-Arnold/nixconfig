-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- Or execute your favorite apps at launch like this:

hl.on("hyprland.start", function()
    hl.exec_cmd("sh -c 'systemctl --user import-environment WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE XDG_CURRENT_DESKTOP DESKTOP_SESSION XDG_SESSION_TYPE; systemctl --user start graphical-session.target; systemctl --user restart hyprpaper.service'")
end)
