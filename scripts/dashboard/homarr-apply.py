#!/usr/bin/env python3
"""Bring Homarr's boards and app catalog in line with homarr-spec.json.

Uses only Homarr's documented REST API (/api/openapi), so it does what the API
allows and nothing more:

- creates boards from the spec that don't exist yet (it never changes or
  replaces a board's content; widgets and layout are edited in the UI)
- sets the home board
- creates apps that are missing and updates apps whose fields differ
- never deletes anything; apps that exist only in Homarr are listed

Entries whose href still says TODO are skipped and reported.

It's a dry run unless you pass --apply. The API key acts as the admin who
created it, so it's read from HOMARR_API_KEY or a hidden prompt, never from
the command line, and nothing stores it. Delete the key afterwards
(Management, Tools, API).

usage:
  scripts/dashboard/homarr-apply.py [--url https://dashboard.servicestack.xyz] [--apply]
"""
import argparse
import getpass
import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

ICON_BASE = "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/"
DEFAULT_SPEC = pathlib.Path(__file__).with_name("homarr-spec.json")

# Operations this script relies on; it refuses to run if the instance doesn't
# document all of them.
REQUIRED = [
    ("get", "/api/boards"),
    ("post", "/api/boards"),
    ("get", "/api/apps"),
    ("post", "/api/apps"),
    ("patch", "/api/apps/{id}"),
    ("get", "/api/settings/board"),
    ("patch", "/api/settings/board"),
]


class Homarr:
    def __init__(self, base, key):
        self.base = base.rstrip("/")
        self.key = key

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method.upper())
        req.add_header("ApiKey", self.key)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:300]
            sys.exit(f"{method.upper()} {path} failed: HTTP {err.code} {detail}")
        except urllib.error.URLError as err:
            sys.exit(f"cannot reach {self.base}: {err.reason}")
        return json.loads(raw) if raw else None


def app_fields(app):
    """Spec entry -> the exact body Homarr's POST/PATCH /api/apps expects."""
    icon = app["icon"]
    return {
        "name": app["name"],
        "description": app.get("description"),
        "iconUrl": icon if icon.startswith(("http://", "https://")) else ICON_BASE + icon + ".svg",
        "href": app.get("href"),
        "pingUrl": app.get("pingUrl"),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="https://dashboard.servicestack.xyz")
    ap.add_argument("--spec", default=str(DEFAULT_SPEC))
    ap.add_argument("--apply", action="store_true", help="make the changes (default: only show them)")
    args = ap.parse_args()

    spec = json.loads(pathlib.Path(args.spec).read_text())
    key = os.environ.get("HOMARR_API_KEY") or getpass.getpass("Homarr API key: ")
    if not key:
        sys.exit("no API key")
    homarr = Homarr(args.url, key)

    documented = homarr.call("get", "/api/openapi").get("paths", {})
    missing = [f"{m.upper()} {p}" for m, p in REQUIRED if m not in documented.get(p, {})]
    if missing:
        sys.exit("this Homarr doesn't document: " + ", ".join(missing))

    mode = "applying" if args.apply else "dry run (pass --apply to make these changes)"
    print(f"{args.url}: {mode}")
    changes = 0

    # Boards: create the missing ones, leave existing ones alone.
    boards = {b["name"]: b for b in homarr.call("get", "/api/boards")}
    for board in spec["boards"]:
        if board["name"] in boards:
            print(f"  = board {board['name']}")
            continue
        changes += 1
        print(f"  + board {board['name']} ({board['columns']} columns, private)")
        if args.apply:
            homarr.call("post", "/api/boards", {"name": board["name"], "columnCount": board["columns"], "isPublic": False})
    if args.apply:
        boards = {b["name"]: b for b in homarr.call("get", "/api/boards")}

    home = spec.get("homeBoard")
    if home:
        settings = homarr.call("get", "/api/settings/board")
        target = boards.get(home, {}).get("id")
        if target is None and not args.apply:
            changes += 1
            print(f"  ~ home board -> {home} (after it's created)")
        elif target is None:
            sys.exit(f"home board {home} doesn't exist")
        elif settings.get("homeBoardId") != target:
            changes += 1
            print(f"  ~ home board -> {home}")
            if args.apply:
                homarr.call("patch", "/api/settings/board", {"homeBoardId": target})
        else:
            print(f"  = home board {home}")

    # Apps: create missing, update changed, never delete.
    existing = {a["name"]: a for a in homarr.call("get", "/api/apps")}
    skipped = []
    for app in spec["apps"]:
        if "TODO" in (app.get("href") or ""):
            skipped.append(app["name"])
            continue
        want = app_fields(app)
        have = existing.get(app["name"])
        if have is None:
            changes += 1
            print(f"  + app {app['name']} -> {want['href']}")
            if args.apply:
                homarr.call("post", "/api/apps", want)
            continue
        diff = sorted(k for k in want if (have.get(k) or None) != (want[k] or None))
        if diff:
            changes += 1
            print(f"  ~ app {app['name']}: {', '.join(diff)}")
            if args.apply:
                homarr.call("patch", f"/api/apps/{have['id']}", want)
        else:
            print(f"  = app {app['name']}")

    spec_names = {a["name"] for a in spec["apps"]}
    for name in sorted(set(existing) - spec_names):
        print(f"  ? app {name} exists only in Homarr (left alone)")
    for name in skipped:
        print(f"  - app {name} skipped: href is still TODO in the spec")

    print(f"{changes} change(s) {'made' if args.apply else 'pending'}")


if __name__ == "__main__":
    main()
