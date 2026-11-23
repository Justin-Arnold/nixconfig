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

-- XWayland apps draw at 1x and get stretched on the 1.25-scaled side
-- monitors. Nearest-neighbor stretching makes their text jagged; linear
-- filtering keeps it smooth, if a little soft.
hl.config({
    xwayland = {
        use_nearest_neighbor = false,
    },
})