local keybindings = require("hyprland.data.keybindings")

-- Screenshots
hl.bind(keybindings.main_mod .. " + SHIFT + S", hl.dsp.exec_cmd("grimblast copy area"), {
    description = "Screenshot an area to the clipboard",
})

-- Wallpaper: swap to the next Gneiss design (gneiss-wallpaper, in
-- home/apps/hyprpaper.nix).
hl.bind(keybindings.main_mod .. " + F11", hl.dsp.exec_cmd("/etc/profiles/per-user/justin/bin/gneiss-wallpaper next"), {
    description = "Swap the wallpaper",
})
