-- https://wiki.hypr.land/Configuring/Basics/Monitors/

local displays = require("hyprland.data.displays")

-- Center Monitor
hl.monitor({
    output   = displays.center.desc,
    mode     = "preferred",
    position = "0x0",
    scale    = "1",
})

-- Left Monitor
hl.monitor({
    output   = displays.left.desc,
    mode     = "preferred",
    position = "-2048x-300",
    scale    = "1.25",
})

-- Right Monitor
hl.monitor({
    output   = displays.right.desc,
    mode     = "preferred",
    position = "3440x-400",
    scale    = "1.25",
})