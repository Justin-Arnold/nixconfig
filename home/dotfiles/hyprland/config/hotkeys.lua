-- Hotkey hints.
--
-- Hold Super for a moment and a notification lists every bind that builds
-- on the modifiers you are holding: add Ctrl, Shift or Alt and the list
-- narrows to those. Releasing Super hides it. Pressing any other key during
-- the hold means you knew what you wanted, so the list stays away.
--
-- Super + / searches every bind by what it does, in vicinae (hypr-hotkeys,
-- in home/apps/hyprland.nix).
--
-- Both show the `description` each bind is given. This file has to be
-- required before any other bind is made: it wraps hl.bind so that every
-- bind with a description, the generated scene binds included, is recorded
-- here for the hint.

local keybindings = require("hyprland.data.keybindings")

local M = {}

-- How long Super has to be held before the hint shows.
M.delay_ms = 1000

local search_cmd = "/etc/profiles/per-user/justin/bin/hypr-hotkeys"

-- Modifier names as bind strings spell them.
local MOD_NAMES = {
    SUPER = "super", WIN = "super", LOGO = "super", META = "super", MOD4 = "super",
    CTRL = "ctrl", CONTROL = "ctrl",
    SHIFT = "shift",
    ALT = "alt", MOD1 = "alt",
}
local MOD_ORDER = { "super", "ctrl", "shift", "alt" }
local MOD_LABELS = { super = "Super", ctrl = "Ctrl", shift = "Shift", alt = "Alt" }

-- XKB keycodes (evdev + 8) of the left and right modifier keys, as the
-- input.keyboard.key event and hl.is_key_down use them.
local MOD_KEYCODES = {
    super = { 133, 134 },
    ctrl = { 37, 105 },
    shift = { 50, 62 },
    alt = { 64, 108 },
}
local KEYCODE_MODS = {}
for mod, codes in pairs(MOD_KEYCODES) do
    for _, code in ipairs(codes) do
        KEYCODE_MODS[code] = mod
    end
end

local KEY_LABELS = { slash = "/", grave = "`", Return = "Enter", Escape = "Esc" }

local trigger = MOD_NAMES[keybindings.main_mod:upper()] or "super"

-- Recorded binds: { mods = { super = true, ... }, key = "H", description = "..." }
M.binds = {}

--- Splits a bind string such as "SUPER + CTRL + H" into a set of modifiers
--- and the key.
function M.parse(keys)
    local mods, key = {}, nil
    for raw in keys:gmatch("[^+]+") do
        local part = raw:match("^%s*(.-)%s*$")
        local mod = MOD_NAMES[part:upper()]
        if mod then
            mods[mod] = true
        elseif part ~= "" then
            key = part
        end
    end
    return mods, key
end

local raw_bind = hl.bind
function hl.bind(keys, action, ...)
    local result = table.pack(raw_bind(keys, action, ...))
    local opts = ...
    local description = type(opts) == "table" and (opts.description or opts.desc)
    if type(keys) == "string" and type(description) == "string" then
        local mods, key = M.parse(keys)
        if key then
            table.insert(M.binds, { mods = mods, key = key, description = description })
        end
    end
    return table.unpack(result, 1, result.n)
end

-- "Resize window (narrower)" -> "Resize window", "narrower"
local function split_variant(description)
    local stem, variant = description:match("^(.-)%s*%(([^()]*)%)$")
    if stem and stem ~= "" then
        return stem, variant
    end
    return description, nil
end

--- The hint for a set of held modifiers. Binds that differ only in their
--- key and the bracketed end of their description share a line:
--- "H J K L  →  Resize window (narrower/taller/shorter/wider)".
function M.hint_text(held)
    local sections, by_label = {}, {}
    for _, bind in ipairs(M.binds) do
        local covers = true
        for mod in pairs(held) do
            if not bind.mods[mod] then
                covers = false
                break
            end
        end
        if covers then
            local extra, rank = {}, ""
            for i, mod in ipairs(MOD_ORDER) do
                if bind.mods[mod] and not held[mod] then
                    table.insert(extra, MOD_LABELS[mod])
                    rank = rank .. i
                end
            end
            local label = table.concat(extra, " + ")
            local section = by_label[label]
            if not section then
                section = { label = label, size = #extra, rank = rank, rows = {}, by_stem = {} }
                by_label[label] = section
                table.insert(sections, section)
            end
            local stem, variant = split_variant(bind.description)
            local row = section.by_stem[stem]
            if not row then
                row = { stem = stem, entries = {} }
                section.by_stem[stem] = row
                table.insert(section.rows, row)
            end
            table.insert(row.entries, {
                key = KEY_LABELS[bind.key] or bind.key,
                variant = variant,
                description = bind.description,
            })
        end
    end

    local held_labels = {}
    for _, mod in ipairs(MOD_ORDER) do
        if held[mod] then
            table.insert(held_labels, MOD_LABELS[mod])
        end
    end
    local title = table.concat(held_labels, " + ")
    if #sections == 0 then
        return "No hotkeys build on " .. title
    end

    table.sort(sections, function(a, b)
        if a.size ~= b.size then
            return a.size < b.size
        end
        return a.rank < b.rank
    end)

    local lines = { title }
    for _, section in ipairs(sections) do
        if section.label ~= "" then
            table.insert(lines, "")
            table.insert(lines, "+ " .. section.label)
        end
        table.sort(section.rows, function(a, b) return a.stem:lower() < b.stem:lower() end)
        for _, row in ipairs(section.rows) do
            table.sort(row.entries, function(a, b) return a.key < b.key end)
            local keys, variants = {}, {}
            for _, entry in ipairs(row.entries) do
                table.insert(keys, entry.key)
                table.insert(variants, entry.variant)
            end
            local text
            if #row.entries == 1 then
                text = row.entries[1].description
            elseif #variants == #row.entries then
                text = row.stem .. " (" .. table.concat(variants, "/") .. ")"
            else
                text = row.stem
            end
            table.insert(lines, table.concat(keys, " ") .. "  →  " .. text)
        end
    end
    return table.concat(lines, "\n")
end

-- Hold tracking ----------------------------------------------------------

local pending -- timer that shows the hint
local shown -- the hint's notification
local chorded = false -- another key was pressed during this hold

-- The modifiers held right now. The key of the event being handled is
-- taken from the event, as Hyprland may not have recorded it yet.
local function held_mods(keycode, state)
    local held = {}
    for mod, codes in pairs(MOD_KEYCODES) do
        for _, code in ipairs(codes) do
            local down
            if code == keycode then
                down = state == 1
            else
                down = hl.is_key_down(code)
            end
            if down then
                held[mod] = true
            end
        end
    end
    return held
end

local function trigger_down()
    for _, code in ipairs(MOD_KEYCODES[trigger]) do
        if hl.is_key_down(code) then
            return true
        end
    end
    return false
end

local function cancel()
    if pending then
        pending:set_enabled(false)
        pending = nil
    end
end

local function hide()
    cancel()
    if shown then
        shown:dismiss()
        shown = nil
    end
end

local function show(held)
    local text = M.hint_text(held)
    if shown and shown:is_alive() then
        shown:set_text(text)
    else
        shown = hl.notification.create({ text = text, timeout = 60000, icon = "none" })
    end
end

function M.on_key(keycode, state)
    if state ~= 0 and state ~= 1 then
        return
    end

    if not KEYCODE_MODS[keycode] then
        if state == 1 and trigger_down() then
            chorded = true
            cancel()
        end
        return
    end

    local held = held_mods(keycode, state)
    if not held[trigger] then
        chorded = false
        hide()
        return
    end

    if shown then
        show(held)
    elseif not pending and not chorded then
        pending = hl.timer(function()
            pending = nil
            local now = held_mods()
            if now[trigger] and not chorded then
                show(now)
            end
        end, { timeout = M.delay_ms, type = "oneshot" })
    end
end

hl.on("input.keyboard.key", function(keycode, _, state)
    M.on_key(keycode, state)
end)

hl.bind(
    keybindings.main_mod .. " + slash",
    hl.dsp.exec_cmd(search_cmd),
    { description = "Search hotkeys" }
)

return M
