#!/usr/bin/env python3
"""Make a service's Paperclip key on an agent and put it into SOPS without
printing it.

Some services on agents read Paperclip as an agent rather than the board:
Paperclip's live events take agent keys only, and an agent key can't change
anything outside that agent's reach. SERVICES says which agent each one's
key belongs to, and which SOPS file and path it goes to.

It signs in like paperclip-apply.py, with a link to approve in the browser
where you're signed in to Paperclip. Then it:

1. makes a key named after the service on its agent, with no scope, since
   the live events refuse a scoped key;
2. writes it to the service's place in SOPS with `sops set`, passing the
   value on stdin;
3. revokes its own sign-in key.

If SOPS can't take it, the new key is revoked, so none is left unused. A key
of that name made earlier keeps working until you revoke it, so the running
service isn't cut off before you switch agents. Once you have,
--revoke-old revokes every key of that name on that agent but the newest,
and makes none.

SOPS_AGE_KEY_FILE defaults to ~/.config/sops/age/keys.txt, the operator key.

usage:
  scripts/agents/paperclip-agent-key.py <service> [--revoke-old] [--url https://paperclip.servicestack.xyz]
"""
import argparse
import importlib.util
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
SPEC = HERE / "paperclip-spec.json"
# service: (the agent its key is on, the SOPS file it goes in, and where)
SERVICES = {
    "paperclip-events": ("Researcher", "secrets/hosts/agents.yaml", '["paperclip-events"]["paperclip-key"]'),
    "agent-watch": ("Researcher", "secrets/hosts/agents.yaml", '["agent-watch"]["paperclip-key"]'),
    # n8n on the automation VM, which reads the triage routine's open issues and nothing else
    # (n8n-apply.py holds that credential to one GET).
    "n8n": ("Researcher", "secrets/hosts/automation.yaml", '["paperclip"]["n8n-key"]'),
}


def load_apply():
    spec = importlib.util.spec_from_file_location("paperclip_apply", HERE / "paperclip-apply.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def find_agent(pc, name):
    prefix = json.loads(SPEC.read_text())["company"]["issuePrefix"]
    company = next((c for c in pc.call("get", "/api/companies") or [] if c.get("issuePrefix") == prefix), None)
    if company is None:
        sys.exit(f"no company with issue prefix {prefix}")
    agent = next((a for a in pc.call("get", f"/api/companies/{company['id']}/agents") or [] if a.get("name") == name), None)
    if agent is None:
        sys.exit(f"no agent named {name}")
    return agent


def service_keys(pc, agent, name):
    keys = [k for k in pc.call("get", f"/api/agents/{agent['id']}/keys") or []
            if k.get("name") == name and not k.get("revokedAt")]
    return sorted(keys, key=lambda k: k.get("createdAt") or "")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("service", choices=sorted(SERVICES))
    ap.add_argument("--revoke-old", action="store_true", help="revoke every key of this name but the newest, and make none")
    ap.add_argument("--url", default="https://paperclip.servicestack.xyz")
    args = ap.parse_args()
    agent_name, sops_file, sops_path = SERVICES[args.service]
    sops_file = REPO / sops_file
    env = {**os.environ, "SOPS_AGE_KEY_FILE": os.environ.get("SOPS_AGE_KEY_FILE",
                                                              str(pathlib.Path.home() / ".config/sops/age/keys.txt"))}
    if not args.revoke_old and not pathlib.Path(env["SOPS_AGE_KEY_FILE"]).is_file():
        sys.exit(f"no age key at {env['SOPS_AGE_KEY_FILE']}: set SOPS_AGE_KEY_FILE to the operator key")

    apply = load_apply()
    pc = apply.Paperclip(args.url)
    pc.key = apply.sign_in(pc, command="paperclip-agent-key", client="scripts/agents/paperclip-agent-key.py")
    try:
        agent = find_agent(pc, agent_name)
        if args.revoke_old:
            keys = service_keys(pc, agent, args.service)
            for key in keys[:-1]:
                pc.call("delete", f"/api/agents/{agent['id']}/keys/{key['id']}")
                print(f"revoked the {args.service} key made {key.get('createdAt')}")
            print(f"kept the newest, made {keys[-1].get('createdAt')}" if keys else f"there's no {args.service} key")
            return

        older = service_keys(pc, agent, args.service)
        key = pc.call("post", f"/api/agents/{agent['id']}/keys", {"name": args.service})
        # The value goes to sops on stdin, JSON-encoded as `sops set` wants it.
        done = subprocess.run(["sops", "set", "--value-stdin", str(sops_file), sops_path],
                              input=json.dumps(key["token"]), text=True, env=env, capture_output=True)
        if done.returncode != 0:
            pc.call("delete", f"/api/agents/{agent['id']}/keys/{key['id']}")
            sys.exit(f"sops couldn't set {sops_path}, so the new key is revoked: {done.stderr.strip()[:300]}")
        where = "/".join(part.strip('"') for part in sops_path.strip("[]").split("]["))
        print(f"made a key named {args.service} on {agent_name}, and put it in "
              f"{sops_file.relative_to(REPO)} at {where}")
        if older:
            print(f"{len(older)} older {args.service} key(s) still work. Once {args.service} uses the new one, "
                  "run this again with --revoke-old.")
    finally:
        try:
            pc.call("post", "/api/cli-auth/revoke-current")
        except SystemExit as err:
            print(f"couldn't revoke this run's sign-in key: {err}", file=sys.stderr)


if __name__ == "__main__":
    main()
