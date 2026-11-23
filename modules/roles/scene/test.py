#!/usr/bin/env python3
"""Runs scene.py against a fake Hyprland, launcher, clipboard and notifier.

Every external command scene calls (hyprctl, uwsm, gio, sh, wl-copy,
notify-send) is replaced by a recorder on PATH. The fake launchers make a
window "appear" by adding it to the list the fake hyprctl reports, and the
fake hyprctl honours placement rules the way Hyprland does: a window whose
class matches a rule is born on that rule's workspace. So opening a scene
runs for real: rule, launch, wait for the window, check its place.

The Lua that scene sends to Hyprland for a rule is also run in a real Lua
interpreter against a stand-in for Hyprland's API, when `lua` is on PATH.

usage: test.py <scene.py>
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

SCRIPT = sys.argv[1]
failures = []

FAKES = {
    "hyprctl": r"""
        a = sys.argv[1:]
        if a[:2] == ["-j", "clients"]:
            print(json.dumps(read("clients.json", [])))
        elif a[:1] == ["dispatch"]:
            log("dispatch.log", a[1])
            print("no such window" if (S / "dispatch-fails").exists() else "ok")
        elif a[:1] == ["eval"]:
            log("eval.log", a[1])
            if (S / "eval-fails").exists():
                print("error: attempt to call a nil value (field 'window_rule')")
            else:
                head = re.match(r"local name, class, now = '(?:[^'\\]|\\.)*', '((?:[^'\\]|\\.)*)', os\.time\(\); ", a[1])
                effect = re.search(r"match = \{ class = class \}, workspace = '(\S+) silent'", a[1])
                if head and effect:
                    # What the code leaves in Hyprland: one rule in force for the class.
                    cls = head.group(1).replace("\\\\", "\\")
                    write("rules.json", [r for r in read("rules.json", []) if r["class"] != cls] + [{
                        "class": cls, "workspace": effect.group(1), "floating": "float = true" in a[1]}])
                print("ok")
        elif a[:1] == ["notify"]:
            log("notifications.log", "hyprctl " + " ".join(a[1:]))
        else:
            sys.exit(1)
    """,
    "uwsm": r"""
        a = sys.argv[1:]
        if a == ["check", "is-active"]:
            sys.exit(1 if (S / "uwsm-inactive").exists() else 0)
        if a[:2] == ["app", "--"]:
            log("launches.log", "uwsm " + " ".join(a[2:]))
            spawn(" ".join(a[2:]))
    """,
    "gio": r"""
        a = sys.argv[1:]
        log("launches.log", "gio " + " ".join(a))
        spawn(os.path.basename(a[-1]))
    """,
    "sh": r"""
        a = sys.argv[1:]
        log("launches.log", "sh " + " ".join(a))
        spawn(a[-1])
    """,
    "wl-copy": r"""
        (S / "clipboard.txt").write_text(sys.stdin.read())
    """,
    "notify-send": r"""
        log("notifications.log", "notify-send " + " ".join(sys.argv[1:]))
    """,
}

FAKE_HEADER = r"""#!@PYTHON@ -I
import json, os, pathlib, re, sys, time
S = pathlib.Path(os.environ["FAKE"])
def log(name, line):
    with open(S / name, "a") as f:
        f.write(line + "\n")
def read(name, default):
    path = S / name
    return json.loads(path.read_text()) if path.exists() else default
def write(name, value):
    tmp = S / f"{name}.{os.getpid()}.tmp"
    tmp.write_text(json.dumps(value))
    os.replace(tmp, S / name)
def add(windows):
    # What Hyprland does with a rule: a matching window is born in its place.
    for w in windows:
        for rule in read("rules.json", []):
            if re.search(rule["class"], w["class"]):
                w["workspace"] = {"id": int(rule["workspace"]), "name": rule["workspace"]}
                w["floating"] = w["floating"] or rule["floating"]
    write("clients.json", read("clients.json", []) + windows)
def spawn(key):
    # A list of windows appears at once. {"now", "delay", "later"} is an app
    # with a splash: "now" appears, then is replaced by "later".
    plan = read("spawn.json", {}).get(key)
    if not plan:
        return
    if isinstance(plan, list):
        plan = {"now": plan}
    add(plan["now"])
    if plan.get("later") and os.fork() == 0:
        time.sleep(plan["delay"])
        gone = {w["address"] for w in plan["now"]}
        write("clients.json", [c for c in read("clients.json", []) if c["address"] not in gone])
        add(plan["later"])
        os._exit(0)
"""

# Stands in for Hyprland's Lua API, behaving as Hyprland 0.57's source does
# (config/lua/bindings/LuaBindingsConfigRules.cpp, LuaBindingsToplevel.cpp):
# a rule made under an existing name is that same rule, switched on again,
# with the new effects added to the old; a one-shot timer fires once. It runs
# the rule code scene sends through an app's life: started, started again
# within the minute, sent to another workspace, and found stale.
LUA_HARNESS = r"""
local rules, order, timers, now = {}, {}, {}, 1000
os.time = function() return now end
hl = {
    window_rule = function(spec)
        local rule = rules[spec.name]
        if not rule then
            rule = { name = spec.name, match = {}, effects = {} }
            rules[spec.name] = rule
            order[#order + 1] = rule
        end
        rule.enabled = spec.enabled ~= false
        for k, v in pairs(spec.match) do rule.match[k] = v end
        local added = {}
        for k, v in pairs(spec) do
            if k ~= "name" and k ~= "enabled" and k ~= "match" then added[#added + 1] = k .. "=" .. tostring(v) end
        end
        table.sort(added)
        for _, effect in ipairs(added) do rule.effects[#rule.effects + 1] = effect end
        return {
            set_enabled = function(_, value) assert(type(value) == "boolean"); rule.enabled = value end,
            is_enabled = function() return rule.enabled end,
        }
    end,
    timer = function(callback, opts)
        assert(type(callback) == "function" and math.type(opts.timeout) == "integer" and opts.timeout > 0)
        assert(opts.type == "oneshot")
        timers[#timers + 1] = { callback = callback, at = now + opts.timeout / 1000 }
    end,
}
local function run(path) assert(loadfile(path))() end
local function at(time)     -- move the clock, firing the timers that come due
    local due
    due, timers = timers, {}
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, timer in ipairs(due) do
        if timer.at <= time then now = timer.at; timer.callback() else timers[#timers + 1] = timer end
    end
    now = time
end
local function state()
    local list = {}
    for _, rule in ipairs(order) do
        list[#list + 1] = rule.name .. " " .. rule.match.class .. " [" .. table.concat(rule.effects, " ") .. "] " .. (rule.enabled and "on" or "off")
    end
    print(table.concat(list, "; "))
end
local code2, code5, alacritty = arg[1], arg[2], arg[3]

run(code2); state()                 -- started
at(1050); run(code2); state()       -- started again within the minute: the same rule, nothing added
at(1060); state()                   -- the first start's timer comes due: still on
at(1110); state()                   -- the second start's time is up: off
at(1200); run(code2); at(1210); run(code5); state()     -- sent elsewhere: one rule in force for the app
at(1259); run(code2); at(1270); state()                 -- and back: the timer of the 1210 start changes nothing
timers = {}; at(5000); run(alacritty); state()          -- a rule left on with no timer is switched off
"""


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"\n     {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def window(address, cls, workspace, at=(0, 0), floating=False, size=(800, 600), initial=None):
    special = str(workspace).startswith("special")
    return {"address": address, "mapped": True, "class": cls, "initialClass": initial or cls,
            "workspace": {"id": -98 if special else int(workspace), "name": str(workspace)},
            "floating": floating, "at": list(at), "size": list(size), "pid": 1}


class World:
    """A throwaway home with fake commands, desktop entries and scene files."""

    def __init__(self, tools=tuple(FAKES), config=None):
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.fake = self.root / "fake"
        self.apps = self.root / "share" / "applications"
        self.declared = self.root / "etc" / "scene" / "presets"
        self.saved = self.root / "state" / "scene" / "snapshots"
        for d in (self.fake, self.apps, self.declared, self.root / "bin", self.root / "home"):
            d.mkdir(parents=True)
        for tool in tools:
            body = "\n".join(line[8:] if line.startswith("        ") else line for line in FAKES[tool].splitlines())
            path = self.root / "bin" / tool
            path.write_text(FAKE_HEADER.replace("@PYTHON@", sys.executable) + body + "\n")
            path.chmod(0o755)
        self.clients([])
        self.spawns({})
        if config is not None:
            (self.root / "etc" / "scene" / "config.json").write_text(json.dumps(config))
        self.env = {
            "PATH": str(self.root / "bin"), "HOME": str(self.root / "home"), "FAKE": str(self.fake),
            "XDG_CONFIG_HOME": str(self.root / "home" / ".config"), "XDG_CONFIG_DIRS": str(self.root / "etc"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "XDG_DATA_HOME": str(self.root / "home" / ".local" / "share"), "XDG_DATA_DIRS": str(self.root / "share"),
        }

    def clients(self, windows):
        (self.fake / "clients.json").write_text(json.dumps(windows))

    def now(self):
        return json.loads((self.fake / "clients.json").read_text())

    def spawns(self, mapping):
        (self.fake / "spawn.json").write_text(json.dumps(mapping))

    def desktop(self, app_id, exec_line=None, **fields):
        lines = ["[Desktop Entry]", "Type=Application", f"Name={app_id}", f"Exec={exec_line or app_id}"]
        lines += [f"{k}={v}" for k, v in fields.items()]
        (self.apps / f"{app_id}.desktop").write_text("\n".join(lines) + "\n[Desktop Action new]\nExec=other\n")

    def declare(self, name, windows, key=None):
        (self.declared / f"{name}.json").write_text(json.dumps({"key": key, "windows": windows}))

    def log(self, name):
        path = self.fake / name
        return path.read_text().splitlines() if path.exists() else []

    def scene(self, *args):
        p = subprocess.run([sys.executable, "-I", SCRIPT, *args], env=self.env, capture_output=True, text=True, timeout=60)
        return p.returncode, p.stdout, p.stderr


def standard_apps(world):
    world.desktop("discord", "Discord")
    world.desktop("code", "code %F", StartupWMClass="Code")
    world.desktop("Alacritty", "alacritty")
    world.desktop("com.anthropic.Claude", "claude-desktop %U")
    world.desktop("md.obsidian.Obsidian", "obsidian %u")
    world.desktop("gitkraken", "gitkraken %U")
    world.desktop("codex-desktop", "env BAMF_DESKTOP_FILE_HINT=/x /nix/store/abc/bin/codex-app")
    world.desktop("scene-open-work", "scene open work --notify", **{"X-Scene-Generated": "true"})


# --- which app a window is -------------------------------------------------
w = World()
standard_apps(w)
w.clients([
    window("0x1", "discord", 4),                      # the desktop file name
    window("0x2", "alacritty", 1),                    # the name, ignoring case
    window("0x3", "Code", 1, at=(900, 0)),            # StartupWMClass
    window("0x4", "claude", 7),                       # last part of a reverse-DNS name
    window("0x5", "codex-app", 7, at=(0, 500)),       # the program Exec runs, past `env VAR=…`
    window("0x6", "scene", 2),                        # must not match a generated launcher entry
    window("0x7", "weird", 2, at=(50, 0), initial="obsidian"),  # the initial class
])
code, out, err = w.scene("save", "--dry-run")
apps = [e["app"] for e in json.loads(out[:out.rindex("}") + 1])["windows"]]
check("window classes lead to desktop entries by name, case, StartupWMClass, reverse-DNS tail, Exec and initial class",
      code == 0 and apps == ["Alacritty", "code", "scene", "md.obsidian.Obsidian", "discord", "com.anthropic.Claude", "codex-desktop"],
      f"{apps} {err}")
check("a class with no desktop entry is named in the summary",
      out.strip().endswith("would save last: 7 windows; no desktop entry for scene"), out[-200:])
check("a dry run saves nothing", not w.saved.exists())

# --- save ------------------------------------------------------------------
w = World()
standard_apps(w)
w.declare("work", [{"app": "discord", "workspace": "4"}])
w.clients([
    window("0xa", "discord", 10),
    window("0xb", "code", 2, at=(500, 0)),
    window("0xc", "code", 2, at=(0, 300)),                      # second window of one app on one workspace
    window("0xd", "code", 1),                                   # the same app on another workspace
    window("0xe", "alacritty", 2, at=(-300, 100), floating=True, size=(1200, 800)),
    window("0xf", "alacritty", "special:terminal-popout"),      # special workspaces are left out
    window("0x10", "mystery", 2, at=(900, 0)),
])
code, out, err = w.scene("save")
saved = json.loads((w.saved / "last.json").read_text()) if (w.saved / "last.json").exists() else {}
check("save writes one entry per app per workspace, by workspace number then position",
      code == 0 and saved.get("windows") == [
          {"app": "code", "workspace": "1"},
          {"app": "Alacritty", "workspace": "2", "floating": True, "size": [1200, 800], "position": [-300, 100]},
          {"app": "code", "workspace": "2"},
          {"app": "mystery", "workspace": "2", "class": "mystery"},
          {"app": "discord", "workspace": "10"},
      ], f"{saved} {err}")
check("save says what it did", out.strip() == "saved last: 5 windows; no desktop entry for mystery", out)
code, out, err = w.scene("save", "work")
check("save refuses the name of a preset", code == 2 and "is a preset" in err and not (w.saved / "work.json").exists(), err)
code, out, err = w.scene("save", "../x")
check("save refuses a name that is not a plain file name", code == 2 and "not a usable scene name" in err, err)
code, out, err = w.scene("list")
check("list shows presets and snapshots",
      code == 0 and out.splitlines() == ["work             preset     1 windows", "last             snapshot   5 windows"], out)
code, out, err = w.scene("show", "last")
check("show prints a scene", code == 0 and json.loads(out) == saved, out)

# --- open ------------------------------------------------------------------
FAST = {"timeout": 1.5, "repeat_timeout": 0.3, "poll": 0.02}
WORK = [
    {"app": "discord", "workspace": "4"},                                    # running, elsewhere: left alone
    {"app": "code", "workspace": "2"},                                       # started
    {"app": "Alacritty", "workspace": "3", "floating": True, "size": [1200, 800], "position": [-300, 100]},
    {"app": "com.anthropic.Claude", "workspace": "7"},                       # started
    {"app": "mystery", "workspace": "5"},                                    # nothing to start it with
    {"app": "md.obsidian.Obsidian", "workspace": "7"},                       # started, no window ever
]
WORK_SPAWNS = {
    "code.desktop": [window("0xc0de", "Code", 1)],
    "Alacritty.desktop": [window("0xa1ac", "Alacritty", 1)],
    "com.anthropic.Claude.desktop": [window("0xc1a0", "claude", 1)],
}

w = World(config=FAST)
standard_apps(w)
w.declare("work", WORK)
w.clients([window("0xd15c", "discord", 1)])
w.spawns(WORK_SPAWNS)
code, out, err = w.scene("open", "work")
evals = w.log("eval.log")
check("open starts only the apps that are not running, each by desktop entry",
      w.log("launches.log") == ["uwsm code.desktop", "uwsm Alacritty.desktop", "uwsm com.anthropic.Claude.desktop",
                                "uwsm md.obsidian.Obsidian.desktop"], str(w.log("launches.log")))
check("before starting an app, open gives Hyprland a rule for the classes its windows can have",
      len(evals) == 4
      and evals[0].startswith(r"local name, class, now = 'scene:code|Code:2', '^(code|Code)$', os.time(); ")
      and "match = { class = class }, workspace = '2 silent' })" in evals[0]
      and evals[1].startswith(r"local name, class, now = 'scene:Alacritty|alacritty:3:float', '^(Alacritty|alacritty)$', os.time(); ")
      and "match = { class = class }, workspace = '3 silent', float = true })" in evals[1]
      and evals[2].startswith(r"local name, class, now = 'scene:com.anthropic.Claude|com.anthropic.claude|Claude|claude:7', "
                              r"'^(com\\.anthropic\\.Claude|com\\.anthropic\\.claude|Claude|claude)$', os.time(); ")
      and all("{ timeout = 60000, type = 'oneshot' }" in e for e in evals), "\n".join(evals))
check("a window born in place by its rule is not moved, only sized and positioned if it floats",
      w.log("dispatch.log") == [
          "hl.dsp.window.resize({ x = 1200, y = 800, window = 'address:0xa1ac' })",
          "hl.dsp.window.move({ x = -300, y = 100, relative = false, window = 'address:0xa1ac' })",
      ] and {c["address"]: c["workspace"]["name"] for c in w.now()} == {"0xd15c": "1", "0xc0de": "2", "0xa1ac": "3", "0xc1a0": "7"},
      "\n".join(w.log("dispatch.log")) + str(w.now()))
check("open reports each app and fails when one could not be opened",
      code == 1 and out.splitlines() == [
          "already open  discord",
          "opened        code on workspace 2",
          "opened        Alacritty on workspace 3",
          "opened        com.anthropic.Claude on workspace 7",
          'cannot open   mystery: no desktop entry (set "command")',
          "timed out     md.obsidian.Obsidian",
          'work: opened 3, already open 1; failed: mystery (no desktop entry (set "command")), md.obsidian.Obsidian (no window appeared)',
      ], out + err)

w = World(config=FAST)
standard_apps(w)
(w.fake / "eval-fails").touch()
w.declare("work", WORK)
w.clients([window("0xd15c", "discord", 1)])
w.spawns(WORK_SPAWNS)
code, out, err = w.scene("open", "work")
check("when Hyprland refuses a rule, open says so once and moves each window after it appears",
      len(w.log("eval.log")) == 1 and w.log("dispatch.log") == [
          "hl.dsp.window.move({ workspace = '2', follow = false, window = 'address:0xc0de' })",
          "hl.dsp.window.move({ workspace = '3', follow = false, window = 'address:0xa1ac' })",
          "hl.dsp.window.float({ action = 'on', window = 'address:0xa1ac' })",
          "hl.dsp.window.resize({ x = 1200, y = 800, window = 'address:0xa1ac' })",
          "hl.dsp.window.move({ x = -300, y = 100, relative = false, window = 'address:0xa1ac' })",
          "hl.dsp.window.move({ workspace = '7', follow = false, window = 'address:0xc1a0' })",
      ] and out.splitlines()[:5] == [
          "already open  discord",
          "note: Hyprland refused a placement rule (error: attempt to call a nil value (field 'window_rule')); windows are moved after they open",
          "opened        code on workspace 2 (moved after it opened)",
          "opened        Alacritty on workspace 3 (moved after it opened)",
          "opened        com.anthropic.Claude on workspace 7 (moved after it opened)",
      ] and out.splitlines()[-1].startswith("work: opened 3 (3 moved after opening), already open 1; failed: "),
      "\n".join(w.log("dispatch.log")) + out + err)

# An app that shows a splash and replaces it with its real window after scene
# has finished, which is what GitKraken and Discord do on a cold start.
w = World(config=FAST)
standard_apps(w)
w.declare("git", [{"app": "gitkraken", "workspace": "4"}])
w.spawns({"gitkraken.desktop": {"now": [window("0x5b1a", "gitkraken", 1, floating=True, size=(200, 475))],
                               "delay": 0.5, "later": [window("0x3ea1", "gitkraken", 1)]}})
code, out, err = w.scene("open", "git")
at_exit = {c["address"] for c in w.now()}
deadline = time.time() + 10
while "0x3ea1" not in {c["address"] for c in w.now()} and time.time() < deadline:
    time.sleep(0.05)
check("a real window that replaces a splash after open has finished is still born on the app's workspace",
      code == 0 and at_exit == {"0x5b1a"} and not w.log("dispatch.log")
      and [(c["address"], c["workspace"]["name"]) for c in w.now()] == [("0x3ea1", "4")]
      and out.splitlines() == ["opened        gitkraken on workspace 4", "git: opened 1, already open 0"],
      f"{at_exit} {w.now()} {out} {err}")

w = World(config=FAST)
standard_apps(w)
w.declare("odd", [{"app": "codex-desktop", "workspace": "7"}])
w.spawns({"codex-desktop.desktop": [window("0xc0d3", "codex-app", 1)]})
code, out, err = w.scene("open", "odd")
check("a window whose class the rule could not predict is moved after it appears, and open says so",
      code == 0 and w.log("dispatch.log") == ["hl.dsp.window.move({ workspace = '7', follow = false, window = 'address:0xc0d3' })"]
      and out.splitlines() == ["opened        codex-desktop on workspace 7 (moved after it opened)",
                               "odd: opened 1 (1 moved after opening), already open 0"], out + err)

w = World(config=FAST)
standard_apps(w)
w.declare("work", [{"app": "discord", "workspace": "4"}, {"app": "code", "workspace": "2"}])
w.clients([window("0xd15c", "discord", 1)])
w.spawns({"code.desktop": [window("0xc0de", "Code", 1)]})
code, out, err = w.scene("open", "work", "--dry-run")
check("a dry run starts nothing, moves nothing and sets no rule",
      code == 0 and not w.log("launches.log") and not w.log("dispatch.log") and not w.log("eval.log")
      and out.splitlines() == ["already open  discord", "would open    code on workspace 2", "work: would open 1, already open 1"], out + err)

w = World(config=FAST)
standard_apps(w)
w.declare("two", [{"app": "discord", "workspace": "4"}, {"app": "discord", "workspace": "5"},
                  {"app": "code", "workspace": "1"}, {"app": "code", "workspace": "2"}])
w.clients([window("0xd15c", "discord", 4), window("0xc0de", "code", 1)])
w.spawns({"code.desktop": [window("0xc0d2", "code", 1)]})
code, out, err = w.scene("open", "two")
check("a second entry for a running app gets no rule; its window is moved if one comes, and none is not a failure",
      code == 0 and not w.log("eval.log")
      and out.splitlines() == ["already open  discord", "no new window discord (already running)",
                               "already open  code", "opened        code on workspace 2 (moved after it opened)",
                               "two: opened 1 (1 moved after opening), already open 2"]
      and w.log("dispatch.log") == ["hl.dsp.window.move({ workspace = '2', follow = false, window = 'address:0xc0d2' })"],
      out + err)

w = World(config=FAST)
standard_apps(w)
(w.fake / "uwsm-inactive").touch()
w.declare("plain", [{"app": "alacritty", "workspace": "1"},
                    {"app": "notes", "workspace": "2", "class": "notes-popup", "command": "alacritty --class notes-popup"}])
w.spawns({"Alacritty.desktop": [window("0xa1ac", "Alacritty", 1)],
          "alacritty --class notes-popup": [window("0x907e", "notes-popup", 1)]})
code, out, err = w.scene("open", "plain")
check("outside a UWSM session apps start through gio, a command runs as given, and a given class is the rule's",
      code == 0 and w.log("launches.log") == [f"gio launch {w.apps / 'Alacritty.desktop'}", "sh -c alacritty --class notes-popup"]
      and w.log("eval.log")[1].startswith(r"local name, class, now = 'scene:notes-popup:2', '^(notes\\-popup)$', os.time(); ")
      and not w.log("dispatch.log") and {c["address"]: c["workspace"]["name"] for c in w.now()} == {"0xa1ac": "1", "0x907e": "2"},
      f"{w.log('launches.log')} {w.log('eval.log')} {w.log('dispatch.log')} {out} {err}")

w = World(config=FAST)
standard_apps(w)
w.declare("cmd", [{"app": "notes", "workspace": "2", "class": "notes-popup", "command": "alacritty --class notes-popup"},
                  {"app": "Alacritty"}])
w.spawns({"sh -c alacritty --class notes-popup": [window("0x907e", "notes-popup", 1)],
          "Alacritty.desktop": [window("0xa1ac", "Alacritty", 1)]})
code, out, err = w.scene("open", "cmd")
check("in a UWSM session a command is started as its own unit, and an entry with no workspace gets no rule",
      code == 0 and w.log("launches.log") == ["uwsm sh -c alacritty --class notes-popup", "uwsm Alacritty.desktop"]
      and len(w.log("eval.log")) == 1 and not w.log("dispatch.log")
      and out.splitlines()[1] == "opened        Alacritty on the current workspace", out + err)

w = World(config=FAST)
standard_apps(w)
(w.fake / "dispatch-fails").touch()
(w.fake / "eval-fails").touch()
w.declare("work", [{"app": "code", "workspace": "2"}])
w.spawns({"code.desktop": [window("0xc0de", "Code", 1)]})
code, out, err = w.scene("open", "work", "--notify")
check("a refused move stops with the answer Hyprland gave, also as a critical notification",
      code == 2 and "answered: no such window" in err
      and len(w.log("notifications.log")) == 1 and w.log("notifications.log")[0].startswith("notify-send -a scene -i preferences-system-windows -u critical Scene hyprctl dispatch"),
      err + str(w.log("notifications.log")))

w = World(config=dict(FAST, rule_seconds=90))
standard_apps(w)
w.clients([window("0xd15c", "discord", 4)])
w.scene("save")
w.clients([])
w.spawns({"discord.desktop": [window("0xd15d", "discord", 1)]})
code, out, err = w.scene("restore", "--notify")
check("restore reopens the last snapshot in place, for the configured time, and reports it as a notification",
      code == 0 and not w.log("dispatch.log") and w.now()[0]["workspace"]["name"] == "4"
      and "{ timeout = 90000, type = 'oneshot' }" in w.log("eval.log")[0] and "r.expires = now + 90; " in w.log("eval.log")[0]
      and w.log("notifications.log")[-1] == "notify-send -a scene -i preferences-system-windows Scene last: opened 1, already open 0",
      out + err + str(w.log("notifications.log")))

# --- the rule, run as Lua ----------------------------------------------------
lua = shutil.which("lua")
if lua is None and os.environ.get("SCENE_TEST_NEEDS_LUA"):
    check("lua is on PATH to run the rule code", False)
elif lua is None:
    print("SKIP the rule code is not run as Lua: no lua on PATH")
else:
    work = pathlib.Path(tempfile.mkdtemp())
    (work / "harness.lua").write_text(LUA_HARNESS)
    w = World(config=FAST)
    standard_apps(w)
    w.declare("moved", [{"app": "code", "workspace": "5"}])
    w.spawns({"code.desktop": [window("0xc0de", "Code", 1)]})
    w.scene("open", "moved")
    (work / "code2.lua").write_text(evals[0])
    (work / "code5.lua").write_text(w.log("eval.log")[0])
    (work / "alacritty.lua").write_text(evals[1])
    p = subprocess.run([lua, str(work / "harness.lua"), str(work / "code2.lua"), str(work / "code5.lua"),
                        str(work / "alacritty.lua")], capture_output=True, text=True)
    CODE2 = "scene:code|Code:2 ^(code|Code)$ [workspace=2 silent]"
    CODE5 = "scene:code|Code:5 ^(code|Code)$ [workspace=5 silent]"
    check("the rule code is valid Lua: one rule per app and place, made once and then switched; starting the app "
          "again keeps it on for the full time; only the latest place of an app is in force; a stale rule is switched off",
          p.returncode == 0 and p.stdout.splitlines() == [
              f"{CODE2} on",
              f"{CODE2} on",
              f"{CODE2} on",
              f"{CODE2} off",
              f"{CODE2} off; {CODE5} on",
              f"{CODE2} on; {CODE5} off",
              f"{CODE2} off; {CODE5} off; scene:Alacritty|alacritty:3:float ^(Alacritty|alacritty)$ [float=true workspace=3 silent] on",
          ], p.stdout + p.stderr)

w = World(tools=("hyprctl", "uwsm"), config=FAST)
standard_apps(w)
w.clients([window("0xd15c", "discord", 4)])
code, out, err = w.scene("save", "--notify")
check("without notify-send the result goes to Hyprland's own notification",
      code == 0 and w.log("notifications.log") == ["hyprctl 1 6000 0 Scene: saved last: 1 window"], str(w.log("notifications.log")))
code, out, err = w.scene("export", "--copy")
check("copying without wl-copy fails and says so", code == 2 and "wl-copy is not installed" in err, err)

# --- export ----------------------------------------------------------------
w = World(config={"nix_attr": "roles.scene.presets"})
standard_apps(w)
w.clients([
    window("0x1", "discord", 4),
    window("0x2", "alacritty", 2, at=(-300, -40), floating=True, size=(1200, 800)),
    window("0x3", 'odd"${x}', 2, at=(10, 0)),
])
EXPECTED = '''# Generated by `scene export`.
{ ... }:
{
  roles.scene.presets.new-scene = {
    key = null;
    windows = [
      { app = "Alacritty"; workspace = "2"; floating = true; size = [ 1200 800 ]; position = [ (-300) (-40) ]; }
      { app = "odd\\"\\${x}"; workspace = "2"; class = "odd\\"\\${x}"; }  # no desktop entry found: add command = "...";
      { app = "discord"; workspace = "4"; }
    ];
  };
}
'''
code, out, err = w.scene("export")
check("export prints the current layout as a Nix file, with negative numbers and odd strings made safe",
      code == 0 and out == EXPECTED, out + err)
code, out, err = w.scene("export", "gaming", "--copy", "--notify")
check("export --copy puts the Nix on the clipboard under the given name and says so",
      code == 0 and (w.fake / "clipboard.txt").read_text() == EXPECTED.replace("new-scene", "gaming")
      and out.strip() == "Copied Nix for 3 windows" and w.log("notifications.log")[-1].endswith("Scene Copied Nix for 3 windows"),
      out + err)
w.declare("work", [{"app": "discord", "workspace": "4"}], key="SUPER + ALT + W")
code, out, err = w.scene("export", "9lives", "--from", "work")
check("export --from prints an existing scene, keeping its key and quoting a name Nix would not take bare",
      code == 0 and '  roles.scene.presets."9lives" = {\n    key = "SUPER + ALT + W";\n    windows = [\n      { app = "discord"; workspace = "4"; }\n' in out, out + err)
if os.environ.get("SCENE_TEST_NIX_OUT"):
    pathlib.Path(os.environ["SCENE_TEST_NIX_OUT"]).write_text(EXPECTED)

# --- keybinds and launcher entries -----------------------------------------
w = World(config={"program": "/run/current-system/sw/bin/scene",
                  "keys": {"save": "SUPER + ALT + S", "restore": "SUPER + ALT + R", "export": None}})
w.declare("work", [{"app": "discord", "workspace": "4"}], key="SUPER + ALT + W")
w.declare("gaming", [{"app": "discord", "workspace": "4"}])
code, out, err = w.scene("binds")
check("binds prints one Hyprland bind per configured key and none for a key left unset",
      code == 0 and out.splitlines() == [
          "-- Generated by `scene binds`.",
          'hl.bind("SUPER + ALT + W", hl.dsp.exec_cmd("/run/current-system/sw/bin/scene open work --notify"), { description = \'Scene: work\' })',
          'hl.bind("SUPER + ALT + S", hl.dsp.exec_cmd("/run/current-system/sw/bin/scene save --notify"), { description = \'Scene: Save snapshot\' })',
          'hl.bind("SUPER + ALT + R", hl.dsp.exec_cmd("/run/current-system/sw/bin/scene restore --notify"), { description = \'Scene: Restore last snapshot\' })',
      ], out + err)
entries = w.root / "entries"
code, out, err = w.scene("desktop-entries", "--out", str(entries))
names = sorted(p.name for p in entries.iterdir()) if entries.exists() else []
text = (entries / "scene-open-work.desktop").read_text() if "scene-open-work.desktop" in names else ""
check("desktop-entries writes a launcher entry for every scene and action, keyed or not",
      code == 0 and names == ["scene-export.desktop", "scene-open-gaming.desktop", "scene-open-work.desktop",
                              "scene-restore.desktop", "scene-save.desktop"]
      and "Name=Scene: work\n" in text and "Exec=/run/current-system/sw/bin/scene open work --notify\n" in text
      and "X-Scene-Generated=true\n" in text
      and "Exec=/run/current-system/sw/bin/scene export --copy --notify\n" in (entries / "scene-export.desktop").read_text(),
      f"{names} {text} {err}")

if failures:
    sys.exit(f"{len(failures)} check(s) failed")
print("all checks passed")
