-- Loads the whole Hyprland config against a stand-in for Hyprland's Lua API
-- and checks the hotkey hints: that every bind has a description, what the
-- hint says for a set of held modifiers, and when it shows and hides.
--
-- usage: lua test.lua <dir holding hyprland/init.lua>

local root = assert(arg[1], "usage: lua test.lua <config dir>")
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
    if ok then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (detail and ("\n     " .. tostring(detail):gsub("\n", "\n     ")) or ""))
    end
end

-- The stand-in ---------------------------------------------------------

-- Anything not modelled below is a callable, indexable no-op.
local anything = setmetatable({}, {
    __index = function(self) return self end,
    __call = function(self) return self end,
})

local binds, handlers, timers, notifications, down = {}, {}, {}, {}, {}

hl = setmetatable({
    bind = function(keys, action, opts)
        table.insert(binds, { keys = keys, opts = opts })
        return anything
    end,
    on = function(event, fn)
        handlers[event] = handlers[event] or {}
        table.insert(handlers[event], fn)
        return anything
    end,
    timer = function(fn, opts)
        local timer = { fn = fn, timeout = opts.timeout, type = opts.type, enabled = true }
        function timer:set_enabled(value) self.enabled = value end
        table.insert(timers, timer)
        return timer
    end,
    notification = {
        create = function(opts)
            local n = { text = opts.text, timeout = opts.timeout, alive = true }
            function n:set_text(text) self.text = text end
            function n:dismiss() self.alive = false end
            function n:is_alive() return self.alive end
            table.insert(notifications, n)
            return n
        end,
    },
    is_key_down = function(code) return down[code] == true end,
    plugin = setmetatable({ hy3 = anything }, { __index = function() return anything end }),
    dsp = anything,
}, { __index = function() return anything end })

-- The generated scene binds, as `scene binds` writes them.
local scene_file = "/etc/xdg/scene/hyprland.lua"
local scene_binds = [[hl.bind("SUPER + ALT + S", hl.dsp.exec_cmd("scene save --notify"), { description = 'Scene: Save snapshot' })]]
local real_open, real_dofile = io.open, dofile
io.open = function(path, ...)
    if path == scene_file then return { close = function() end } end
    return real_open(path, ...)
end
dofile = function(path)
    if path == scene_file then return assert(load(scene_binds))() end
    return real_dofile(path)
end

require("hyprland.init")
local hotkeys = require("hyprland.config.hotkeys")

-- Binds ----------------------------------------------------------------

local missing, seen, duplicates = {}, {}, {}
for _, bind in ipairs(binds) do
    local opts = bind.opts or {}
    if not (opts.description or opts.desc) then
        table.insert(missing, bind.keys)
    end
    local mods, key = hotkeys.parse(bind.keys)
    local names = {}
    for mod in pairs(mods) do table.insert(names, mod) end
    table.sort(names)
    local combo = table.concat(names, "+") .. "+" .. tostring(key)
    if seen[combo] then table.insert(duplicates, bind.keys) end
    seen[combo] = true
end
check("the config makes its binds", #binds > 30, #binds .. " binds")
check("every bind has a description", #missing == 0, table.concat(missing, ", "))
check("no two binds share a key combination", #duplicates == 0, table.concat(duplicates, ", "))
check("every described bind is recorded for the hint, scene binds included",
      #hotkeys.binds == #binds, #hotkeys.binds .. " of " .. #binds)

local function has_line(text, line)
    for l in (text .. "\n"):gmatch("(.-)\n") do
        if l == line then return true end
    end
    return false
end

-- Hint text ------------------------------------------------------------

local super = hotkeys.hint_text({ super = true })
check("holding Super lists the Super binds under a title", super:match("^Super\n") ~= nil, super)
check("binds that differ only in key and the bracketed end share a line",
      has_line(super, "H J K L  →  Focus window (left/down/up/right)"), super)
check("a bind of its own keeps its whole description",
      has_line(super, "Tab  →  Next workspace in group (Tab mode)"), super)
check("keys are shown the way they are printed", has_line(super, "/  →  Search hotkeys"), super)
check("binds with more modifiers come in their own sections",
      super:find("\n%+ Ctrl\n") and super:find("\n%+ Shift\n") and super:find("\n%+ Alt\n")
      and super:find("\n%+ Ctrl\n") < super:find("\n%+ Shift\n"), super)
check("generated scene binds are listed", has_line(super, "S  →  Scene: Save snapshot"), super)

local ctrl = hotkeys.hint_text({ super = true, ctrl = true })
check("adding Ctrl narrows the list to binds that build on Super + Ctrl",
      ctrl:match("^Super %+ Ctrl\n") and not ctrl:find("Focus window")
      and has_line(ctrl, "H J K L  →  Resize window (narrower/taller/shorter/wider)")
      and has_line(ctrl, "1 2 3  →  Send window to workspace group (center/left/right)"), ctrl)

local none = hotkeys.hint_text({ super = true, ctrl = true, shift = true, alt = true })
check("a set of modifiers with no binds says so", none == "No hotkeys build on Super + Ctrl + Shift + Alt", none)

-- Showing and hiding ---------------------------------------------------

local SUPER, CTRL, ONE, A = 133, 37, 10, 38

-- Hyprland may record a key after the event runs, so the stand-in does too.
local function key(code, state)
    for _, fn in ipairs(handlers["input.keyboard.key"]) do
        fn(code, 0, state)
    end
    down[code] = state == 1 or nil
end
local function press(code) key(code, 1) end
local function release(code) key(code, 0) end
local function fire(timer)
    if timer and timer.enabled then
        timer.enabled = false
        timer.fn()
    end
end
local function latest() return notifications[#notifications] end

press(SUPER)
local timer = timers[#timers]
check("holding Super starts a one-shot timer of the configured delay",
      timer and timer.type == "oneshot" and timer.timeout == hotkeys.delay_ms and #notifications == 0)
fire(timer)
check("when the timer fires, the hint shows", #notifications == 1 and latest().alive and latest().text == super,
      latest() and latest().text)

press(CTRL)
check("adding Ctrl while the hint shows narrows it in place", #notifications == 1 and latest().text == ctrl,
      latest().text)
release(CTRL)
check("letting go of Ctrl widens it again", latest().text == super, latest().text)
release(SUPER)
check("letting go of Super hides it", not latest().alive)

local before = #timers
press(SUPER)
press(ONE)
check("pressing another key during the hold stops the timer", #timers == before + 1 and not timers[#timers].enabled)
release(ONE)
press(CTRL)
check("and no new timer starts for the rest of that hold", #timers == before + 1)
release(CTRL)
release(SUPER)
check("so the hint never shows", #notifications == 1)

press(A)
release(A)
press(SUPER)
fire(timers[#timers])
check("typing before Super is held does not stop the hint", #notifications == 2 and latest().alive)
press(ONE)
check("a key pressed once the hint shows leaves it up", latest().alive)
release(ONE)
release(SUPER)
check("letting go of Super still hides it", not latest().alive)

press(SUPER)
local early = timers[#timers]
release(SUPER)
fire(early)
check("letting go before the delay means the hint never shows", not early.enabled and #notifications == 2)

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("all checks passed")
