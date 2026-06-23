local keybindings = require("hyprland.data.keybindings")

local M = {}

local popouts = {
    aichat = {
        class = "aichat-popup",
        workspace = "aichat-popout",
    },
    codex = {
        class = "codex-popup",
        workspace = "codex-popout",
    },
    terminal = {
        class = "terminal-popup",
        workspace = "terminal-popout",
    },
    oterm = {
        class = "oterm-popup",
        workspace = "oterm-popout",
    },
}

local function toggle_popout(name)
    return hl.dsp.exec_cmd("hypr-popout toggle " .. name)
end

local function popout_rule(popout, size)
    hl.window_rule({
        name = popout.class,
        match = {
            class = "^(" .. popout.class .. ")$",
        },
        float = true,
        size = size,
        center = true,
        workspace = "special:" .. popout.workspace .. " silent",
        opacity = "0.90 0.90",
        dim_around = true,
    })
end

function M.close_or_hide_active()
    return hl.dsp.exec_cmd("hypr-popout close-active")
end

popout_rule(popouts.aichat, { 800, 600 })
popout_rule(popouts.codex, { 800, 600 })
popout_rule(popouts.terminal, { 1000, 700 })
popout_rule(popouts.oterm, { 1200, 900 })

hl.on("hyprland.start", function()
    hl.exec_cmd("hypr-popout start all")
end)

-- Popup keybinds
hl.bind(
    "SUPER + SHIFT + Space",
    toggle_popout("aichat")
)

hl.bind(
    "SUPER + CTRL + SHIFT + Space",
    toggle_popout("oterm")
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + C",
    toggle_popout("codex")
)

hl.bind(
    keybindings.main_mod .. " + SHIFT + T",
    toggle_popout("terminal")
)

return M
