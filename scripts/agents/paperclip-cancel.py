#!/usr/bin/env python3
"""Cancel Paperclip issues by their identifiers, such as LAB-29.

It looks each one up first and lists its title and status. Issues that are
already done or cancelled are left alone; the rest are cancelled once you
confirm, or straight away with --yes. If any identifier isn't found, nothing
is cancelled. A cancelled issue can be reopened in Paperclip, and nothing is
deleted.

It acts as the board and signs in like paperclip-apply.py: with
PAPERCLIP_BOARD_KEY set it uses that key; otherwise it prints a link to
approve in the browser where you're signed in to Paperclip, and revokes the
key that sign-in gave it before it exits.

usage:
  scripts/agents/paperclip-cancel.py LAB-29 LAB-33 [--yes] [--url https://paperclip.servicestack.xyz]
"""
import argparse
import importlib.util
import os
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
IDENTIFIER = re.compile(r"^[A-Z][A-Z0-9]*-\d+$")
LEAVE = {"done", "cancelled"}


def load_apply():
    spec = importlib.util.spec_from_file_location("paperclip_apply", HERE / "paperclip-apply.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("issues", nargs="+", metavar="ISSUE", help="identifiers, such as LAB-29")
    ap.add_argument("--yes", action="store_true", help="cancel without asking")
    ap.add_argument("--url", default="https://paperclip.servicestack.xyz")
    args = ap.parse_args()
    wanted = list(dict.fromkeys(i.strip().upper() for i in args.issues))
    bad = [i for i in wanted if not IDENTIFIER.match(i)]
    if bad:
        sys.exit(f"not an issue identifier: {', '.join(bad)} (expected something like LAB-29)")

    apply = load_apply()
    pc = apply.Paperclip(args.url)
    pc.key = os.environ.get("PAPERCLIP_BOARD_KEY")
    signed_in = not pc.key
    if signed_in:
        pc.key = apply.sign_in(pc, command="paperclip-cancel", client="scripts/agents/paperclip-cancel.py")
    try:
        found = [pc.call("get", f"/api/issues/{ident}") for ident in wanted]
        todo = []
        for issue in found:
            note = "already " + issue["status"] + ", left alone" if issue["status"] in LEAVE else issue["status"]
            print(f"  {issue['identifier']}  {note}  {issue['title']}")
            if issue["status"] not in LEAVE:
                todo.append(issue)
        if not todo:
            print("nothing to cancel")
            return
        if not args.yes:
            answer = input(f"Cancel {len(todo)} issue(s)? [y/N] ").strip().lower()
            if answer not in ("y", "yes"):
                print("nothing cancelled")
                return
        for issue in todo:
            pc.call("patch", f"/api/issues/{issue['id']}", {"status": "cancelled"})
            print(f"cancelled {issue['identifier']}")
    finally:
        if signed_in:
            try:
                pc.call("post", "/api/cli-auth/revoke-current")
            except SystemExit as err:
                print(f"couldn't revoke this run's board key: {err}", file=sys.stderr)


if __name__ == "__main__":
    main()
