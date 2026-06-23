local keybindings = require("hyprland.data.keybindings")

-- Screenshots
hl.bind(keybindings.main_mod .. " + SHIFT + S", hl.dsp.exec_cmd("grimblast copy area"))
