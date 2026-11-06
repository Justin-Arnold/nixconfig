#!/usr/bin/env python3
"""Make board-bridge's board key and put it into SOPS without printing it.

It signs in like paperclip-apply.py, with a link to approve in the browser
where you're signed in to Paperclip. Then it:

1. makes a board key named board-bridge that doesn't expire (the key a
   sign-in gives lasts 30 days);
2. writes it to paperclip/board-bridge-key in secrets/hosts/agents.yaml with
   `sops set`, passing the value on stdin;
3. revokes its own sign-in key.

If SOPS can't take it, the new key is revoked, so none is left unused. A
board-bridge key made earlier keeps working until you revoke it, so the
running bridge isn't cut off before you switch agents. Once you have,
--revoke-old revokes every board-bridge key but the newest, and makes none.

SOPS_AGE_KEY_FILE defaults to ~/.config/sops/age/keys.txt, the operator key.

usage:
  scripts/agents/paperclip-board-key.py [--revoke-old] [--url https://paperclip.servicestack.xyz]
"""
import argparse
import importlib.util
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
SOPS_FILE = HERE.parent.parent / "secrets/hosts/agents.yaml"
SOPS_PATH = '["paperclip"]["board-bridge-key"]'
NAME = "board-bridge"


def load_apply():
    spec = importlib.util.spec_from_file_location("paperclip_apply", HERE / "paperclip-apply.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def bridge_keys(pc):
    keys = [k for k in pc.call("get", "/api/board-api-keys") or [] if k.get("name") == NAME and not k.get("revokedAt")]
    return sorted(keys, key=lambda k: k.get("createdAt") or "")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--revoke-old", action="store_true", help="revoke every board-bridge key but the newest, and make none")
    ap.add_argument("--url", default="https://paperclip.servicestack.xyz")
    args = ap.parse_args()
    env = {**os.environ, "SOPS_AGE_KEY_FILE": os.environ.get("SOPS_AGE_KEY_FILE",
                                                              str(pathlib.Path.home() / ".config/sops/age/keys.txt"))}
    if not args.revoke_old and not pathlib.Path(env["SOPS_AGE_KEY_FILE"]).is_file():
        sys.exit(f"no age key at {env['SOPS_AGE_KEY_FILE']}: set SOPS_AGE_KEY_FILE to the operator key")

    apply = load_apply()
    pc = apply.Paperclip(args.url)
    pc.key = apply.sign_in(pc, command="paperclip-board-key", client="scripts/agents/paperclip-board-key.py")
    try:
        if args.revoke_old:
            keys = bridge_keys(pc)
            for key in keys[:-1]:
                pc.call("delete", f"/api/board-api-keys/{key['id']}")
                print(f"revoked the board-bridge key made {key.get('createdAt')}")
            print(f"kept the newest, made {keys[-1].get('createdAt')}" if keys else "there's no board-bridge key")
            return

        older = bridge_keys(pc)
        key = pc.call("post", "/api/board-api-keys", {"name": NAME, "expiresAt": None})
        # The value goes to sops on stdin, JSON-encoded as `sops set` wants it.
        done = subprocess.run(["sops", "set", "--value-stdin", str(SOPS_FILE), SOPS_PATH],
                              input=json.dumps(key["token"]), text=True, env=env, capture_output=True)
        if done.returncode != 0:
            pc.call("delete", f"/api/board-api-keys/{key['id']}")
            sys.exit(f"sops couldn't set {SOPS_PATH}, so the new key is revoked: {done.stderr.strip()[:300]}")
        print(f"made a board key named {NAME} that doesn't expire, and put it in "
              f"{SOPS_FILE.relative_to(HERE.parent.parent)} at paperclip/board-bridge-key")
        if older:
            print(f"{len(older)} older board-bridge key(s) still work. Once agents is switched, run this "
                  "again with --revoke-old.")
    finally:
        try:
            pc.call("post", "/api/cli-auth/revoke-current")
        except SystemExit as err:
            print(f"couldn't revoke this run's sign-in key: {err}", file=sys.stderr)


if __name__ == "__main__":
    main()
