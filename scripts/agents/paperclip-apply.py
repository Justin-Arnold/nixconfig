#!/usr/bin/env python3
"""Bring Paperclip's company, labels and agents in line with paperclip-spec.json.

Uses only Paperclip's documented REST API (/api/openapi.json), and only for
what the spec names:

- the company, found by its issue prefix: whether a new agent waits for the
  board's approval
- labels: creates the missing ones. Paperclip can't change a label, so a
  colour that differs is only reported.
- agents, matched by name: role, reporting line, the adapter settings the
  spec lists, timed heartbeats, and whether they may create agents. Keys the
  spec leaves out are left alone. A Hermes agent that's missing is hired with
  its API key taken from the company secret named in apiKeySecret, and
  approved. Other agents, like the concierge, join through an invite, so
  they're never created, and their adapter settings are only reported.
- never deletes anything, and never reads or writes a secret's value. An
  agent's API key is only checked to come from a company secret.

It's a dry run unless you pass --apply. It acts as the board. With
PAPERCLIP_BOARD_KEY set it uses that key; otherwise it starts a CLI sign-in,
prints a link to approve in the browser where you're signed in to Paperclip,
and revokes the key that sign-in gave it before it exits.

usage:
  scripts/agents/paperclip-apply.py [--url https://paperclip.servicestack.xyz] [--apply]
"""
import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_SPEC = pathlib.Path(__file__).with_name("paperclip-spec.json")
REDACTED = "***REDACTED***"

# Operations this script relies on; it refuses to run if the instance doesn't
# document all of them.
REQUIRED = [
    ("post", "/api/cli-auth/challenges"),
    ("get", "/api/cli-auth/challenges/{id}"),
    ("post", "/api/cli-auth/revoke-current"),
    ("get", "/api/companies"),
    ("get", "/api/companies/{companyId}"),
    ("patch", "/api/companies/{companyId}"),
    ("get", "/api/companies/{companyId}/labels"),
    ("post", "/api/companies/{companyId}/labels"),
    ("get", "/api/companies/{companyId}/secrets"),
    ("get", "/api/companies/{companyId}/agents"),
    ("post", "/api/companies/{companyId}/agent-hires"),
    ("patch", "/api/agents/{id}"),
    ("patch", "/api/agents/{id}/permissions"),
    ("post", "/api/agents/{id}/approve"),
]

# What Paperclip assumes when an agent's runtimeConfig.heartbeat doesn't say.
HEARTBEAT_DEFAULTS = {"enabled": False, "intervalSec": 0, "wakeOnDemand": True}

# Adapters whose settings this script changes. The OpenClaw adapter keeps its
# gateway token and device key in the same settings, so it's only checked.
PATCHABLE_ADAPTERS = {"hermes_gateway"}


class Paperclip:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.key = None

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method.upper())
        if self.key:
            req.add_header("Authorization", f"Bearer {self.key}")
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:300]
            sys.exit(f"{method.upper()} {path.split('?')[0]} failed: HTTP {err.code} {detail}")
        except urllib.error.URLError as err:
            sys.exit(f"cannot reach {self.base}: {err.reason}")
        return json.loads(raw) if raw else None


def sign_in(pc, command="paperclip-apply", client="scripts/agents/paperclip-apply.py"):
    """A board key from Paperclip's CLI sign-in, once Justin approves it."""
    challenge = pc.call("post", "/api/cli-auth/challenges", {
        "command": command,
        "clientName": client,
        "requestedAccess": "board",
    })
    url = challenge.get("approvalUrl") or pc.base + challenge["approvalPath"]
    print(f"Approve this sign-in in the browser where you're signed in to Paperclip:\n  {url}")
    poll = f"/api{challenge['pollPath']}?token={urllib.parse.quote(challenge['token'])}"
    deadline = time.monotonic() + 600
    while time.monotonic() < deadline:
        status = pc.call("get", poll).get("status")
        if status == "approved":
            return challenge["boardApiToken"]
        if status in ("cancelled", "expired"):
            sys.exit(f"sign-in {status}")
        time.sleep(2)
    sys.exit("sign-in wasn't approved within 10 minutes")


def show(value):
    return json.dumps(value) if not isinstance(value, str) else value


def secret_ref(binding):
    return binding.get("secretId") if isinstance(binding, dict) and binding.get("type") == "secret_ref" else None


def apply(pc, spec, write):
    changes = 0

    # Company: only the settings the spec lists.
    want = spec["company"]
    company = next((c for c in pc.call("get", "/api/companies") if c.get("issuePrefix") == want["issuePrefix"]), None)
    if company is None:
        sys.exit(f"no company with issue prefix {want['issuePrefix']}")
    cid = company["id"]
    company = pc.call("get", f"/api/companies/{cid}")
    patch = {k: v for k, v in want.items() if k != "issuePrefix" and company.get(k) != v}
    if patch:
        changes += 1
        print(f"  ~ company {company['name']}: " + ", ".join(f"{k} {show(company.get(k))} -> {show(v)}" for k, v in patch.items()))
        if write:
            pc.call("patch", f"/api/companies/{cid}", patch)
    else:
        print(f"  = company {company['name']}")

    # Labels: create missing, report a colour that differs, never delete.
    labels = {label["name"]: label for label in pc.call("get", f"/api/companies/{cid}/labels")}
    for label in spec["labels"]:
        have = labels.get(label["name"])
        if have is None:
            changes += 1
            print(f"  + label {label['name']} {label['color']}")
            if write:
                pc.call("post", f"/api/companies/{cid}/labels", {"name": label["name"], "color": label["color"]})
        elif have["color"].lower() != label["color"].lower():
            print(f"  ! label {label['name']} is {have['color']}, the spec says {label['color']} (Paperclip can't change it)")
        else:
            print(f"  = label {label['name']}")
    for name in sorted(set(labels) - {label["name"] for label in spec["labels"]}):
        print(f"  ? label {name} exists only in Paperclip (left alone)")

    # Agents, in spec order so a manager exists before the agents reporting to it.
    secrets = pc.call("get", f"/api/companies/{cid}/secrets")
    secret_by_name = {s["name"]: s for s in secrets}
    secret_name = {s["id"]: s["name"] for s in secrets}
    agents = {a["name"]: a for a in pc.call("get", f"/api/companies/{cid}/agents") if a.get("status") != "terminated"}

    for agent in spec["agents"]:
        name = agent["name"]
        manager = agent.get("reportsTo")
        manager_id = None
        if manager is not None:
            manager_id = agents.get(manager, {}).get("id")
            if manager_id is None and write:
                sys.exit(f"agent {name} reports to {manager}, which doesn't exist")
        heartbeat = agent.get("heartbeat", {})
        role = agent.get("role", "general")
        have = agents.get(name)

        if have is None:
            if agent["adapterType"] not in PATCHABLE_ADAPTERS:
                print(f"  ! agent {name} is missing; a {agent['adapterType']} agent joins through an invite")
                continue
            secret = secret_by_name.get(agent.get("apiKeySecret"))
            if secret is None:
                print(f"  ! agent {name} is missing and can't be hired: its apiKeySecret isn't a company secret")
                continue
            changes += 1
            print(f"  + agent {name} ({role}, {agent['adapterConfig'].get('apiBaseUrl')}, "
                  f"key from secret {secret['name']}, reports to {manager or 'nobody'})")
            if write:
                body = {
                    "name": name,
                    "role": role,
                    "reportsTo": manager_id,
                    "adapterType": agent["adapterType"],
                    "adapterConfig": {
                        **agent["adapterConfig"],
                        "apiKey": {"type": "secret_ref", "secretId": secret["id"], "version": "latest"},
                    },
                    "runtimeConfig": {"heartbeat": heartbeat},
                    "permissions": {"canCreateAgents": agent.get("canCreateAgents", False)},
                }
                for key in ("title", "capabilities"):
                    if key in agent:
                        body[key] = agent[key]
                created = pc.call("post", f"/api/companies/{cid}/agent-hires", body)["agent"]
                if created.get("status") == "pending_approval":
                    created = pc.call("post", f"/api/agents/{created['id']}/approve")
                agents[name] = created
            continue

        notes = []
        patch = {}
        for key in ("role", "title", "capabilities"):
            if key in agent and have.get(key) != agent[key]:
                patch[key] = agent[key]
                notes.append(f"{key} {show(have.get(key))} -> {show(agent[key])}")
        if "reportsTo" in agent and have.get("reportsTo") != manager_id:
            if manager_id is not None or manager is None:
                patch["reportsTo"] = manager_id
            notes.append(f"reports to {manager or 'nobody'}")

        if have.get("adapterType") != agent["adapterType"]:
            print(f"  ! agent {name} uses {have.get('adapterType')}, the spec says {agent['adapterType']} (not changed)")
        else:
            config = have.get("adapterConfig") or {}
            drift = {k: v for k, v in agent["adapterConfig"].items() if config.get(k) != v}
            if drift and agent["adapterType"] in PATCHABLE_ADAPTERS:
                # Paperclip merges these keys into the stored settings, so the
                # API key and anything else not named here stay as they are.
                patch["adapterConfig"] = drift
                notes += [f"{k} {show(config.get(k))} -> {show(v)}" for k, v in drift.items()]
            elif drift:
                for k, v in drift.items():
                    print(f"  ! agent {name}: {k} is {show(config.get(k))}, the spec says {show(v)} (change it in Paperclip)")
            if agent["adapterType"] in PATCHABLE_ADAPTERS:
                secret_id = secret_ref(config.get("apiKey"))
                if secret_id is None:
                    print(f"  ! agent {name}: its API key isn't a company secret reference")
                elif "apiKeySecret" in agent and secret_name.get(secret_id) != agent["apiKeySecret"]:
                    print(f"  ! agent {name}: its API key comes from secret {secret_name.get(secret_id)}, "
                          f"the spec says {agent['apiKeySecret']} (not changed)")

        runtime = have.get("runtimeConfig") or {}
        current = {**HEARTBEAT_DEFAULTS, **(runtime.get("heartbeat") or {})}
        beat = {k: v for k, v in heartbeat.items() if current.get(k) != v}
        if beat:
            # Paperclip replaces runtimeConfig whole, so send it back with only
            # the heartbeat keys changed.
            patch["runtimeConfig"] = {**runtime, "heartbeat": {**(runtime.get("heartbeat") or {}), **beat}}
            notes += [f"heartbeat.{k} {show(current.get(k))} -> {show(v)}" for k, v in beat.items()]
            if REDACTED in json.dumps(patch["runtimeConfig"]):
                sys.exit(f"agent {name}'s runtimeConfig came back redacted; refusing to write it")

        can_create = bool((have.get("permissions") or {}).get("canCreateAgents"))
        permissions = "canCreateAgents" in agent and can_create != agent["canCreateAgents"]
        if permissions:
            notes.append(f"canCreateAgents {show(can_create)} -> {show(agent['canCreateAgents'])}")

        if notes:
            changes += 1
            print(f"  ~ agent {name}: " + ", ".join(notes))
            if write and patch:
                agents[name] = pc.call("patch", f"/api/agents/{have['id']}", patch)
            if write and permissions:
                # Any active member may assign tasks whatever this says.
                pc.call("patch", f"/api/agents/{have['id']}/permissions",
                        {"canCreateAgents": agent["canCreateAgents"], "canAssignTasks": True})
        else:
            key_from = secret_name.get(secret_ref((have.get("adapterConfig") or {}).get("apiKey")))
            print(f"  = agent {name}" + (f" (key from secret {key_from})" if key_from else ""))

    for name in sorted(set(agents) - {agent["name"] for agent in spec["agents"]}):
        print(f"  ? agent {name} exists only in Paperclip (left alone)")
    return changes


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="https://paperclip.servicestack.xyz")
    ap.add_argument("--spec", default=str(DEFAULT_SPEC))
    ap.add_argument("--apply", action="store_true", help="make the changes (default: only show them)")
    args = ap.parse_args()

    spec = json.loads(pathlib.Path(args.spec).read_text())
    pc = Paperclip(args.url)

    documented = pc.call("get", "/api/openapi.json").get("paths", {})
    missing = [f"{m.upper()} {p}" for m, p in REQUIRED if m not in documented.get(p, {})]
    if missing:
        sys.exit("this Paperclip doesn't document: " + ", ".join(missing))

    pc.key = os.environ.get("PAPERCLIP_BOARD_KEY")
    signed_in = not pc.key
    if signed_in:
        pc.key = sign_in(pc)
    try:
        mode = "applying" if args.apply else "dry run (pass --apply to make these changes)"
        print(f"{args.url}: {mode}")
        changes = apply(pc, spec, args.apply)
        print(f"{changes} change(s) {'made' if args.apply else 'pending'}")
    finally:
        if signed_in:
            try:
                pc.call("post", "/api/cli-auth/revoke-current")
            except SystemExit as err:
                print(f"couldn't revoke this run's board key: {err}", file=sys.stderr)


if __name__ == "__main__":
    main()
