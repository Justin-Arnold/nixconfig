#!/usr/bin/env python3
"""Runs lock-diff.py on two small flake.lock files and checks the table.

It checks that a moved GitHub input gets both revisions with their dates and
a compare link, an unchanged one is only counted, a `follows` is skipped, a
new and a removed input are marked, a renamed transitive node that didn't
move isn't counted while one that did is, a non-GitHub input shows its hash,
and that two identical locks say nothing moved.

usage: lock-diff-test.py <lock-diff.py>
"""
import json
import pathlib
import subprocess
import sys
import tempfile

SCRIPT = sys.argv[1]
DAY = 86400
NOV_3 = 1793664000  # 2026-11-03 00:00 UTC


def gh(owner, repo, rev, day):
    return {"locked": {"type": "github", "owner": owner, "repo": repo, "rev": rev, "lastModified": NOV_3 + day * DAY,
                       "narHash": "sha256-" + rev[:8]}}


def lock(nodes, inputs):
    return {"nodes": {"root": {"inputs": inputs}, **nodes}, "root": "root", "version": 7}


old = lock({
    "nixpkgs": gh("NixOS", "nixpkgs", "a" * 40, 0),
    "disko": gh("nix-community", "disko", "b" * 40, 0),
    "gone": gh("someone", "gone", "c" * 40, 0),
    "nixpkgs_2": gh("NixOS", "nixpkgs", "d" * 40, 0),
    "flake-utils": gh("numtide", "flake-utils", "e" * 40, 0),
    "local": {"locked": {"type": "path", "path": "/x", "narHash": "sha256-oldhash000000000", "lastModified": NOV_3}},
}, {"nixpkgs": "nixpkgs", "disko": "disko", "gone": "gone", "local": "local", "home-manager": ["nixpkgs"]})

new = lock({
    "nixpkgs": gh("NixOS", "nixpkgs", "f" * 40, 6),
    "disko": gh("nix-community", "disko", "b" * 40, 0),
    "fresh": gh("someone", "fresh", "1" * 40, 6),
    # Renamed but pointing at the same revision: not a move.
    "nixpkgs_3": gh("NixOS", "nixpkgs", "d" * 40, 0),
    "flake-utils": gh("numtide", "flake-utils", "2" * 40, 5),
    "local": {"locked": {"type": "path", "path": "/x", "narHash": "sha256-newhash000000000", "lastModified": NOV_3}},
}, {"nixpkgs": "nixpkgs", "disko": "disko", "fresh": "fresh", "local": "local", "home-manager": ["nixpkgs"]})

tmp = pathlib.Path(tempfile.mkdtemp())
(tmp / "old.lock").write_text(json.dumps(old))
(tmp / "new.lock").write_text(json.dumps(new))

failed = 0


def check(name, ok):
    global failed
    print(("PASS  " if ok else "FAIL  ") + name)
    if not ok:
        failed += 1


def run(a, b):
    done = subprocess.run([sys.executable, "-I", SCRIPT, str(tmp / a), str(tmp / b)], capture_output=True, text=True)
    return done.returncode, done.stdout


code, out = run("old.lock", "new.lock")
print(out)
row = {line.split("|")[1].strip(): line for line in out.splitlines() if line.startswith("| ") and "Input" not in line}
check("exits 0", code == 0)
check("a moved input has both revisions and dates",
      "`aaaaaaa`" in row.get("nixpkgs", "") and "2026-11-03" in row.get("nixpkgs", "")
      and "`fffffff`" in row.get("nixpkgs", "") and "2026-11-09" in row.get("nixpkgs", ""))
check("  ...and a compare link",
      f"https://github.com/NixOS/nixpkgs/compare/{'a' * 40}...{'f' * 40}" in row.get("nixpkgs", ""))
check("  ...and commit links", f"https://github.com/NixOS/nixpkgs/commit/{'f' * 40}" in row.get("nixpkgs", ""))
check("an unchanged input isn't listed", "disko" not in row)
check("  ...but is counted", "Unchanged: 1 input." in out)
check("a follows is skipped", "home-manager" not in row)
check("a new input is marked", "(new)" in row.get("fresh", ""))
check("a removed input is marked", "(removed)" in row.get("gone", ""))
check("a non-GitHub input shows its hash", "sha256-newhash" in row.get("local", ""))
check("a renamed transitive node that didn't move isn't counted, one that did is", "pull in: 1 moved." in out)

code, out = run("old.lock", "old.lock")
check("identical locks: nothing moved", code == 0 and "None of the flake's own inputs moved." in out
      and "pull in: 0 moved." in out)

code, _ = run("old.lock", "missing.lock")
check("a missing file fails", code != 0)

print(f"\nfailed: {failed}")
sys.exit(1 if failed else 0)
