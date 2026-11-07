#!/usr/bin/env python3
"""Describe what moved between two flake.lock files, as a pull request body.

Lists each of the flake's own inputs that moved, with its old and new
revision and date, and a compare link for GitHub inputs. Inputs that only
other inputs pull in are counted, not listed: their node names shift between
locks (nixpkgs_2 becomes nixpkgs_3), so a list of them would mostly be noise.

usage: scripts/ci/lock-diff.py <old flake.lock> <new flake.lock>
"""
import datetime
import json
import sys


def load(path):
    with open(path) as handle:
        return json.load(handle)


def direct(lock):
    """The root's own inputs, by name, as their locked nodes."""
    nodes = lock["nodes"]
    inputs = nodes[lock.get("root", "root")].get("inputs", {})
    # A list is a `follows`: the input is another input's, which is listed already.
    return {name: nodes[key].get("locked", {}) for name, key in inputs.items() if isinstance(key, str)}


def transitive(lock):
    """Every other locked node as what it points at, so a renamed node still matches."""
    root = lock["nodes"][lock.get("root", "root")].get("inputs", {})
    own = {key for key in root.values() if isinstance(key, str)}
    return {(where(node["locked"]), revision(node["locked"]))
            for key, node in lock["nodes"].items() if key not in own and "locked" in node}


def where(locked):
    if locked.get("type") == "github":
        return f"github:{locked.get('owner')}/{locked.get('repo')}"
    return f"{locked.get('type')}:{locked.get('url') or locked.get('path') or ''}"


def revision(locked):
    return locked.get("rev") or locked.get("narHash", "")


def date(locked):
    stamp = locked.get("lastModified")
    if not stamp:
        return ""
    return datetime.datetime.fromtimestamp(stamp, datetime.timezone.utc).strftime("%Y-%m-%d")


def cell(locked):
    rev = revision(locked)
    short = rev[:7] if locked.get("rev") else rev[:15]
    if locked.get("type") == "github" and locked.get("rev"):
        text = f"[`{short}`](https://github.com/{locked['owner']}/{locked['repo']}/commit/{rev})"
    else:
        text = f"`{short}`"
    return f"{text} {date(locked)}".strip()


def compare(old, new):
    if old.get("type") == new.get("type") == "github" and where(old) == where(new) and old.get("rev") and new.get("rev"):
        return f"[diff](https://github.com/{new['owner']}/{new['repo']}/compare/{old['rev']}...{new['rev']})"
    return ""


def describe(old_lock, new_lock):
    old, new = direct(old_lock), direct(new_lock)
    rows = []
    unchanged = 0
    for name in sorted(set(old) | set(new)):
        before, after = old.get(name), new.get(name)
        if before is None:
            rows.append(f"| {name} | (new) | {cell(after)} |")
        elif after is None:
            rows.append(f"| {name} | {cell(before)} | (removed) |")
        elif revision(before) != revision(after) or where(before) != where(after):
            link = compare(before, after)
            rows.append(f"| {name} | {cell(before)} | {cell(after)}{' ' + link if link else ''} |")
        else:
            unchanged += 1

    moved_t = len(transitive(new_lock) - transitive(old_lock))

    lines = []
    if rows:
        lines += ["| Input | From | To |", "|---|---|---|", *rows, ""]
    else:
        lines += ["None of the flake's own inputs moved.", ""]
    lines.append(f"Unchanged: {unchanged} input{'s' if unchanged != 1 else ''}. "
                 f"Inputs that other inputs pull in: {moved_t} moved.")
    return "\n".join(lines)


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: lock-diff.py <old flake.lock> <new flake.lock>")
    print(describe(load(sys.argv[1]), load(sys.argv[2])))


if __name__ == "__main__":
    main()
