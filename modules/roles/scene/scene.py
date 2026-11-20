#!/usr/bin/env python3
"""scene: named sets of apps on their workspaces.

A scene lists apps and where each one belongs. `scene open` starts the ones
that are not running and puts their windows in place; `scene save` writes the
current arrangement as a scene; `scene export` prints it as Nix to declare.

Apps are identified by desktop entry, never by the command a window was
started with, so a scene keeps working when an app's install path changes.
Each app restores its own tabs and documents; scene only handles which apps
are open and where.

Scenes are JSON, one file per scene:

    {"key": "SUPER + ALT + W",
     "windows": [{"app": "discord", "workspace": "4"},
                 {"app": "Alacritty", "workspace": "2", "floating": true,
                  "size": [1200, 800], "position": [100, 100]}]}

  app        desktop entry ID (the .desktop file name without the suffix)
  workspace  workspace the window goes to
  floating, size, position   float the window at that size and place
  class      window class, when it does not lead back to the desktop entry
  command    shell command to start it, for apps with no desktop entry

A scene is either a preset, written by hand or by configuration, or a
snapshot, written by `scene save`. Presets are read from scene/presets/*.json
under $XDG_CONFIG_HOME and $XDG_CONFIG_DIRS; snapshots are kept in
$XDG_STATE_HOME/scene/snapshots. A preset wins over a snapshot of its name.
Settings come from scene/config.json in the same config directories:

  keys       {"save": ..., "restore": ..., "export": ...} for `scene binds`
  nix_attr   attribute path `scene export` writes scenes under
  program    how the generated binds and launcher entries call this tool
  timeout    seconds to wait for a started app's window (default 20)
  rule_seconds  how long after starting an app its new windows are still
             sent to its workspace (default 60)

Placing a window has two parts. Before an app is started, a temporary rule
tells the compositor where that app's windows go, so a splash window and the
real window that replaces it both open in place. The first window is also
checked once it appears and moved if the rule did not catch it; `scene open`
then says "moved after it opened".

Only Hyprland is supported; everything specific to it is in class Hyprland.
"""
import argparse
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import time

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
NIX_ATTR_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_'-]*$")
WINDOW_FIELDS = ("app", "workspace", "floating", "size", "position", "class", "command")
ICON = "preferences-system-windows"


class SceneError(Exception):
    pass


# --------------------------------------------------------------------------
# Files
# --------------------------------------------------------------------------

def _base(var, default):
    value = os.environ.get(var)
    return pathlib.Path(value) if value else pathlib.Path(default).expanduser()


def config_dirs():
    dirs = [_base("XDG_CONFIG_HOME", "~/.config") / "scene"]
    for d in (os.environ.get("XDG_CONFIG_DIRS") or "/etc/xdg").split(":"):
        if d:
            dirs.append(pathlib.Path(d) / "scene")
    return dirs


def state_dir():
    return _base("XDG_STATE_HOME", "~/.local/state") / "scene" / "snapshots"


def data_dirs():
    dirs = [_base("XDG_DATA_HOME", "~/.local/share")]
    for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":"):
        if d:
            dirs.append(pathlib.Path(d))
    return dirs


def load_config():
    for d in config_dirs():
        path = d / "config.json"
        if path.is_file():
            try:
                return json.loads(path.read_text())
            except ValueError as err:
                raise SceneError(f"{path}: {err}")
    return {}


def _scene_files(directory):
    if not directory.is_dir():
        return {}
    return {p.stem: p for p in sorted(directory.glob("*.json")) if NAME_RE.match(p.stem)}


def presets():
    found = {}
    for d in reversed(config_dirs()):  # earlier directories win
        found.update(_scene_files(d / "presets"))
    return found


def snapshots():
    return _scene_files(state_dir())


def check_name(name):
    if not NAME_RE.match(name):
        raise SceneError(f"'{name}' is not a usable scene name (letters, digits, '.', '_' and '-')")
    return name


def read_scene(path):
    try:
        scene = json.loads(path.read_text())
    except ValueError as err:
        raise SceneError(f"{path}: {err}")
    windows = scene.get("windows") if isinstance(scene, dict) else None
    if not isinstance(windows, list) or not all(isinstance(w, dict) and isinstance(w.get("app"), str) for w in windows):
        raise SceneError(f"{path}: a scene needs \"windows\", a list of objects that each have an \"app\"")
    return {"key": scene.get("key"), "windows": windows}


def find_scene(name):
    """A preset wins over a snapshot of the same name."""
    check_name(name)
    for source, scenes in (("preset", presets()), ("snapshot", snapshots())):
        if name in scenes:
            return read_scene(scenes[name]), source
    raise SceneError(f"no scene named '{name}' (see `scene list`)")


# --------------------------------------------------------------------------
# Desktop entries
# --------------------------------------------------------------------------

def _parse_desktop(path):
    entry, in_group = {}, False
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("["):
            in_group = line == "[Desktop Entry]"
        elif in_group and "=" in line and not line.startswith("#"):
            key, value = line.split("=", 1)
            entry.setdefault(key.strip(), value.strip())
    if entry.get("Type", "Application") != "Application":
        return None
    if entry.get("Hidden", "").lower() == "true" or entry.get("X-Scene-Generated", "").lower() == "true":
        return None
    return entry


class Apps:
    """Desktop entries on the XDG data path, and which one a window class means."""

    def __init__(self):
        self.entries = {}
        for base in data_dirs():
            root = base / "applications"
            if not root.is_dir():
                continue
            for path in sorted(root.rglob("*.desktop")):
                app_id = "-".join(path.relative_to(root).with_suffix("").parts)
                if app_id in self.entries:
                    continue  # earlier directories win
                entry = _parse_desktop(path)
                if entry is not None:
                    self.entries[app_id] = {"path": path, "exec": entry.get("Exec", ""),
                                            "wmclass": entry.get("StartupWMClass", "")}
        self._by_id = self._index(lambda i, e: i)
        self._by_wmclass = self._index(lambda i, e: e["wmclass"])
        self._by_tail = self._index(lambda i, e: i.rsplit(".", 1)[-1])
        self._by_exec = self._index(lambda i, e: os.path.basename(_exec_argv0(e["exec"])))

    def _index(self, key):
        index = {}
        for app_id, entry in self.entries.items():
            k = key(app_id, entry).lower()
            if k:
                index.setdefault(k, []).append(app_id)
        return index

    def get(self, app_id):
        """The entry for a desktop ID, ignoring case."""
        if app_id in self.entries:
            return app_id, self.entries[app_id]
        ids = self._by_id.get(app_id.lower())
        return (ids[0], self.entries[ids[0]]) if ids else (None, None)

    def classes(self, app_id):
        """Window classes an app's windows can be expected to have, to match
        them before they exist: the desktop ID, its StartupWMClass and the
        last part of a reverse-DNS ID, each as written and in lower case."""
        found, info = self.get(app_id)
        app_id = found or app_id
        names = []
        for name in (app_id, info["wmclass"] if info else "", app_id.rsplit(".", 1)[-1]):
            for variant in (name, name.lower()):
                if variant and variant not in names:
                    names.append(variant)
        return names

    def resolve(self, window_class):
        """Desktop ID for a window class, or None. The looser matches only
        count when exactly one entry fits."""
        cls = (window_class or "").lower()
        if not cls:
            return None
        for index, unique in ((self._by_id, False), (self._by_wmclass, False),
                              (self._by_tail, True), (self._by_exec, True)):
            ids = index.get(cls)
            if ids and (len(ids) == 1 or not unique):
                return ids[0]
        return None


def _exec_argv0(exec_line):
    """The program an Exec= line runs, past any `env VAR=value` prefix."""
    try:
        argv = shlex.split(exec_line)
    except ValueError:
        return ""
    while argv and (argv[0] == "env" or "=" in argv[0]):
        argv.pop(0)
    return argv[0] if argv else ""


def _exec_without_field_codes(exec_line):
    return re.sub(r"\s*%[a-zA-Z]", "", exec_line).replace("%%", "%")


# --------------------------------------------------------------------------
# Hyprland
# --------------------------------------------------------------------------

def lua_str(text):
    escaped = str(text).replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n")
    return f"'{escaped}'"


class Hyprland:
    """Everything that talks to the compositor. Windows are plain dicts:
    address, class, initial_class, workspace, special, floating, at, size."""

    def _hyprctl(self, *args):
        try:
            p = subprocess.run(["hyprctl", *args], capture_output=True, text=True)
        except OSError as err:
            raise SceneError(f"cannot run hyprctl: {err}")
        return p.returncode, (p.stdout + p.stderr).strip()

    def windows(self):
        code, out = self._hyprctl("-j", "clients")
        try:
            clients = json.loads(out) if code == 0 else None
        except ValueError:
            clients = None
        if clients is None:
            raise SceneError(f"hyprctl could not list windows: {out[:200]}")
        windows = []
        for c in clients:
            if not c.get("mapped", True) or not c.get("class"):
                continue
            workspace = c.get("workspace") or {}
            name = str(workspace.get("name", ""))
            windows.append({
                "address": c["address"],
                "class": c["class"],
                "initial_class": c.get("initialClass") or c["class"],
                "workspace": name,
                "special": workspace.get("id", 0) < 0 or name.startswith("special"),
                "floating": bool(c.get("floating")),
                "at": list(c.get("at") or [0, 0]),
                "size": list(c.get("size") or [0, 0]),
            })
        return windows

    def _dispatch(self, lua):
        code, out = self._hyprctl("dispatch", lua)
        if code != 0 or out != "ok":
            raise SceneError(f"hyprctl dispatch {lua} answered: {out[:200]}")

    def route(self, classes, entry, seconds):
        """Have Hyprland put every window of these classes that opens in the
        next `seconds` on the entry's workspace, from its first frame.

        Apps often show a splash or updater window and replace it with the
        real one seconds later; a rule catches both, where moving the first
        window that appears would miss the second. Hyprland switches the rule
        off itself after `seconds`. Returns None, or why Hyprland refused.

        Hyprland keeps a rule until its config is reloaded, and a rule made
        under an existing name is that same rule with the new effects added
        to the old ones. So a rule is made once per app, workspace and
        floating, and after that only switched on and off; it is off when its
        time is up, when the app is sent somewhere else, and whenever a later
        call finds it past its time."""
        workspace = str(entry["workspace"])
        floating = bool(entry.get("floating"))
        name = lua_str(f"scene:{'|'.join(classes)}:{workspace}" + (":float" if floating else ""))
        pattern = lua_str("^(" + "|".join(re.escape(c) for c in classes) + ")$")
        effects = f"workspace = {lua_str(workspace + ' silent')}" + (", float = true" if floating else "")
        lua = "; ".join([
            f"local name, class, now = {name}, {pattern}, os.time()",
            "__scene_rules = __scene_rules or {}",
            "for other, r in pairs(__scene_rules) do "
            "if r.rule:is_enabled() and (r.expires <= now or (r.class == class and other ~= name)) "
            "then r.rule:set_enabled(false) end end",
            "local r = __scene_rules[name]",
            # is_enabled() is nil for a rule Hyprland no longer has.
            "if not r or r.rule:is_enabled() == nil then "
            f"r = {{ class = class, rule = hl.window_rule({{ name = name, match = {{ class = class }}, {effects} }}) }}; "
            "__scene_rules[name] = r end",
            f"r.expires = now + {int(seconds)}",
            "r.rule:set_enabled(true)",
            # The timer of an earlier start of the same app must not end this one early.
            "hl.timer(function() if r.expires <= os.time() then r.rule:set_enabled(false) end end, "
            f"{{ timeout = {int(seconds * 1000)}, type = 'oneshot' }})",
        ])
        code, out = self._hyprctl("eval", lua)
        return None if code == 0 and out == "ok" else (out[:200] or "no answer")

    def place(self, window, entry):
        """Move a window to the entry's workspace, without following it there,
        and float it at the entry's size and position. Returns whether it had
        to change workspace."""
        target = lua_str("address:" + window["address"])
        workspace = entry.get("workspace")
        moved = workspace is not None and str(workspace) != window["workspace"]
        if moved:
            self._dispatch(f"hl.dsp.window.move({{ workspace = {lua_str(workspace)}, follow = false, window = {target} }})")
        if not entry.get("floating"):
            return moved
        if not window["floating"]:
            self._dispatch(f"hl.dsp.window.float({{ action = 'on', window = {target} }})")
        # Size first: floating a window re-centres it, so the position goes last.
        size, position = entry.get("size"), entry.get("position")
        if size:
            self._dispatch(f"hl.dsp.window.resize({{ x = {int(size[0])}, y = {int(size[1])}, window = {target} }})")
        if position:
            self._dispatch(f"hl.dsp.window.move({{ x = {int(position[0])}, y = {int(position[1])}, relative = false, window = {target} }})")
        return moved

    def bind_line(self, key, command):
        return f"hl.bind({json.dumps(key)}, hl.dsp.exec_cmd({json.dumps(command)}))"

    def notify(self, message):
        self._hyprctl("notify", "1", "6000", "0", message)


# --------------------------------------------------------------------------
# Scenes
# --------------------------------------------------------------------------

def matches(entry, window, apps):
    classes = {window["class"].lower(), window["initial_class"].lower()}
    wanted = entry.get("class")
    if wanted:
        return wanted.lower() in classes
    app = entry["app"].lower()
    if app in classes:
        return True
    resolved = apps.resolve(window["class"]) or apps.resolve(window["initial_class"])
    return resolved is not None and resolved.lower() == app


_uwsm = None


def uwsm_active():
    global _uwsm
    if _uwsm is None:
        _uwsm = bool(shutil.which("uwsm")) and subprocess.run(
            ["uwsm", "check", "is-active"], capture_output=True).returncode == 0
    return _uwsm


def launch_argv(entry, apps):
    """The command that starts an entry's app, as its own unit where the
    session is run by UWSM."""
    command = entry.get("command")
    if command:
        argv = ["sh", "-c", command]
        return ["uwsm", "app", "--", *argv] if uwsm_active() else argv
    app_id, info = apps.get(entry["app"])
    if info is None:
        raise SceneError("no desktop entry (set \"command\")")
    if uwsm_active():
        return ["uwsm", "app", "--", app_id + ".desktop"]
    if shutil.which("gio"):
        return ["gio", "launch", str(info["path"])]
    return ["sh", "-c", _exec_without_field_codes(info["exec"])]


def wait_for_window(backend, entry, apps, known, timeout, poll):
    deadline = time.monotonic() + timeout
    while True:
        for window in backend.windows():
            if window["address"] not in known and matches(entry, window, apps):
                return window
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll)


def where(entry):
    return f"workspace {entry['workspace']}" if entry.get("workspace") is not None else "the current workspace"


def open_scene(name, scene, backend, apps, config, dry_run):
    """Returns (lines to print, summary, whether everything worked)."""
    timeout = float(config.get("timeout", 20))
    repeat_timeout = float(config.get("repeat_timeout", 5))
    poll = float(config.get("poll", 0.2))
    rule_seconds = float(config.get("rule_seconds", 60))
    windows = backend.windows()
    claimed, lines, opened, already, failed = set(), [], 0, 0, []
    moved_after, rules_refused = 0, False
    for entry in scene["windows"]:
        app = entry["app"]
        present = next((w for w in windows if w["address"] not in claimed and matches(entry, w, apps)), None)
        if present is not None:
            claimed.add(present["address"])
            already += 1
            lines.append(f"already open  {app}")
            continue
        # A second entry for an app that is running may get no window of its
        # own: single-instance apps just focus the one they have.
        repeat = any(matches(entry, w, apps) for w in windows)
        try:
            argv = launch_argv(entry, apps)
        except SceneError as err:
            failed.append(f"{app} ({err})")
            lines.append(f"cannot open   {app}: {err}")
            continue
        if dry_run:
            opened += 1
            lines.append(f"would open    {app} on {where(entry)}")
            continue
        # Not for a repeat: its rule would also catch the first entry's windows.
        if entry.get("workspace") is not None and not repeat and not rules_refused:
            classes = [entry["class"]] if entry.get("class") else apps.classes(app)
            refusal = backend.route(classes, entry, rule_seconds)
            if refusal:
                rules_refused = True
                lines.append(f"note: Hyprland refused a placement rule ({refusal}); windows are moved after they open")
        try:
            subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError as err:
            failed.append(f"{app} ({err.strerror})")
            lines.append(f"cannot open   {app}: {err}")
            continue
        window = wait_for_window(backend, entry, apps, {w["address"] for w in windows},
                                 repeat_timeout if repeat else timeout, poll)
        if window is None:
            if repeat:
                lines.append(f"no new window {app} (already running)")
            else:
                failed.append(f"{app} (no window appeared)")
                lines.append(f"timed out     {app}")
            continue
        # With a rule in force the window is already where it belongs; having
        # to move it means the rule did not catch it.
        moved = backend.place(window, entry)
        moved_after += moved
        windows.append(window)
        claimed.add(window["address"])
        opened += 1
        lines.append(f"opened        {app} on {where(entry)}" + (" (moved after it opened)" if moved else ""))
    verb = "would open" if dry_run else "opened"
    summary = f"{name}: {verb} {opened}"
    if moved_after:
        summary += f" ({moved_after} moved after opening)"
    summary += f", already open {already}"
    if failed:
        summary += "; failed: " + ", ".join(failed)
    return lines, summary, not failed


def _workspace_order(name):
    return (0, int(name), "") if name.lstrip("-").isdigit() else (1, 0, name)


def snapshot(backend, apps):
    """The current windows as a scene: one entry per app per workspace, in
    reading order. Returns the scene and the classes with no desktop entry."""
    windows = [w for w in backend.windows() if not w["special"]]
    windows.sort(key=lambda w: (_workspace_order(w["workspace"]), w["at"][0], w["at"][1]))
    entries, seen, unresolved = [], set(), []
    for w in windows:
        app = apps.resolve(w["class"]) or apps.resolve(w["initial_class"])
        entry = {"app": app or w["class"], "workspace": w["workspace"]}
        if (entry["app"], entry["workspace"]) in seen:
            continue
        seen.add((entry["app"], entry["workspace"]))
        if app is None:
            entry["class"] = w["class"]
            unresolved.append(w["class"])
        if w["floating"]:
            entry.update(floating=True, size=w["size"], position=w["at"])
        entries.append(entry)
    return {"key": None, "windows": entries}, unresolved


def scene_json(scene):
    return json.dumps(scene, indent=2) + "\n"


# --------------------------------------------------------------------------
# Nix, keybinds, launcher entries
# --------------------------------------------------------------------------

def nix_str(text):
    escaped = str(text).replace("\\", "\\\\").replace('"', '\\"').replace("${", "\\${").replace("\n", "\\n")
    return f'"{escaped}"'


def nix_value(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        number = int(value)
        return f"({number})" if number < 0 else str(number)  # a bare -1 does not parse inside a list
    if isinstance(value, (list, tuple)):
        return "[ " + " ".join(nix_value(v) for v in value) + " ]"
    return nix_str(value)


def nix_scene(name, scene, attr_path):
    attr = name if NIX_ATTR_RE.match(name) else nix_str(name)
    lines = [
        "# Generated by `scene export`.",
        "{ ... }:",
        "{",
        f"  {attr_path}.{attr} = {{",
        f"    key = {nix_value(scene.get('key'))};",
        "    windows = [",
    ]
    for window in scene["windows"]:
        fields = " ".join(f"{field} = {nix_value(window[field])};" for field in WINDOW_FIELDS
                          if window.get(field) is not None)
        note = ""
        if window.get("class") and not window.get("command"):
            note = '  # no desktop entry found: add command = "...";'
        lines.append(f"      {{ {fields} }}{note}")
    lines += ["    ];", "  };", "}"]
    return "\n".join(lines) + "\n"


def actions(config):
    """(id, title, comment, arguments, key) for everything that gets a keybind
    or a launcher entry."""
    keys = config.get("keys") or {}
    found = []
    for name, path in sorted(presets().items()):
        found.append((name, f"Scene: {name}", f"Open the {name} scene", ["open", name], read_scene(path).get("key")))
    found.append(("save", "Scene: Save snapshot", "Save the open apps and their workspaces", ["save"], keys.get("save")))
    found.append(("restore", "Scene: Restore last snapshot", "Reopen the apps from the last snapshot", ["restore"], keys.get("restore")))
    found.append(("export", "Scene: Copy layout as Nix", "Copy the current layout as a Nix scene", ["export", "--copy"], keys.get("export")))
    return found


def action_command(config, arguments):
    return " ".join([config.get("program", "scene"), *arguments, "--notify"])


def bind_lines(config, backend):
    lines = ["-- Generated by `scene binds`."]
    for _, _, _, arguments, key in actions(config):
        if key:
            lines.append(backend.bind_line(key, action_command(config, arguments)))
    return "\n".join(lines) + "\n"


def desktop_entries(config):
    files = {}
    for action_id, title, comment, arguments, _ in actions(config):
        prefix = "scene-open-" if arguments[0] == "open" else "scene-"
        files[f"{prefix}{action_id}.desktop"] = "\n".join([
            "[Desktop Entry]",
            "Type=Application",
            f"Name={title}",
            f"Comment={comment}",
            f"Exec={action_command(config, arguments)}",
            f"Icon={ICON}",
            "Terminal=false",
            "Categories=Utility;",
            "Keywords=scene;layout;session;workspace;",
            "X-Scene-Generated=true",
            "",
        ])
    return files


# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------

def notify(backend, message, failed=False):
    if shutil.which("notify-send"):
        urgency = ["-u", "critical"] if failed else []
        subprocess.run(["notify-send", "-a", "scene", "-i", ICON, *urgency, "Scene", message], capture_output=True)
    else:
        backend.notify(f"Scene: {message}")


def copy_to_clipboard(text):
    if not shutil.which("wl-copy"):
        raise SceneError("wl-copy is not installed, so nothing was copied")
    if subprocess.run(["wl-copy"], input=text, text=True, capture_output=True).returncode != 0:
        raise SceneError("wl-copy could not set the clipboard")


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="scene", description="Named sets of apps on their workspaces.")
    sub = parser.add_subparsers(dest="command", required=True, metavar="command")

    def add(name, help_text, scene_name=None, dry_run=False, feedback=True):
        p = sub.add_parser(name, help=help_text, description=help_text)
        if scene_name == "required":
            p.add_argument("name", help="scene name")
        elif scene_name is not None:
            p.add_argument("name", nargs="?", default=scene_name, help=f"scene name (default: {scene_name})")
        if dry_run:
            p.add_argument("--dry-run", action="store_true", help="show what would happen and change nothing")
        if feedback:
            p.add_argument("--notify", action="store_true", help="also report the result as a desktop notification")
        return p

    add("open", "Open a scene: start its apps that are not running and place them.", "required", dry_run=True)
    add("restore", "Open a saved snapshot.", "last", dry_run=True)
    add("save", "Save the open apps and their workspaces as a snapshot.", "last", dry_run=True)
    export = add("export", "Print the current layout as a Nix scene.", "new-scene")
    export.add_argument("--from", dest="source", metavar="SCENE", help="export this scene instead of the current layout")
    export.add_argument("--copy", action="store_true", help="put it on the clipboard instead of printing it")
    add("list", "List the presets and snapshots.", feedback=False)
    add("show", "Print a scene.", "required", feedback=False)
    add("binds", "Print Hyprland keybinds for the configured keys.", feedback=False)
    entries = add("desktop-entries", "Write a launcher entry for each scene and action.", feedback=False)
    entries.add_argument("--out", required=True, metavar="DIR", help="directory to write the .desktop files to")
    return parser.parse_args(argv)


def run(args, backend):
    """Returns (text for stdout, summary for the notification, success)."""
    config = load_config()

    if args.command in ("open", "restore"):
        scene, _ = find_scene(args.name)
        lines, summary, ok = open_scene(args.name, scene, backend, Apps(), config, args.dry_run)
        return "\n".join([*lines, summary]), summary, ok

    if args.command == "save":
        check_name(args.name)
        if args.name in presets():
            raise SceneError(f"'{args.name}' is a preset; save under another name")
        scene, unresolved = snapshot(backend, Apps())
        count = len(scene["windows"])
        summary = f"{'would save' if args.dry_run else 'saved'} {args.name}: {count} window{'' if count == 1 else 's'}"
        if unresolved:
            summary += "; no desktop entry for " + ", ".join(unresolved)
        if args.dry_run:
            return scene_json(scene) + summary, summary, True
        state_dir().mkdir(parents=True, exist_ok=True)
        (state_dir() / f"{args.name}.json").write_text(scene_json(scene))
        return summary, summary, True

    if args.command == "export":
        check_name(args.name)
        if args.source:
            scene, _ = find_scene(args.source)
        else:
            scene, _ = snapshot(backend, Apps())
        text = nix_scene(args.name, scene, config.get("nix_attr", "presets"))
        count = len(scene["windows"])
        if args.copy:
            copy_to_clipboard(text)
            summary = f"Copied Nix for {count} window{'' if count == 1 else 's'}"
            return summary, summary, True
        return text.rstrip("\n"), f"Printed Nix for {count} windows", True

    if args.command == "list":
        rows = []
        for source, scenes in (("preset", presets()), ("snapshot", snapshots())):
            for name, path in sorted(scenes.items()):
                if source == "snapshot" and name in presets():
                    continue
                scene = read_scene(path)
                rows.append(f"{name:<16} {source:<9} {len(scene['windows']):>2} windows  {scene.get('key') or ''}".rstrip())
        return "\n".join(rows) if rows else "no scenes", "", True

    if args.command == "show":
        scene, _ = find_scene(args.name)
        return scene_json(scene).rstrip("\n"), "", True

    if args.command == "binds":
        return bind_lines(config, backend).rstrip("\n"), "", True

    if args.command == "desktop-entries":
        out = pathlib.Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        files = desktop_entries(config)
        for filename, text in files.items():
            (out / filename).write_text(text)
        return f"wrote {len(files)} entries to {out}", "", True

    raise SceneError(f"unknown command {args.command}")


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    backend = Hyprland()
    wants_notification = getattr(args, "notify", False)
    try:
        text, summary, ok = run(args, backend)
    except SceneError as err:
        print(f"scene: {err}", file=sys.stderr)
        if wants_notification:
            notify(backend, str(err), failed=True)
        return 2
    if text:
        print(text)
    if wants_notification and summary:
        notify(backend, summary, failed=not ok)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
