#!/usr/bin/env python3
"""Bring Paperclip's company, labels, agents and routines in line with paperclip-spec.json.

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
- routines, matched by title: description (from the markdown file the spec
  names), assignee, priority, concurrency and catch-up policies, declared
  variables, and triggers matched by label. A routine that's missing is
  created active. A routine paused or archived in Paperclip stays that way.
- webhook triggers, for n8n: signed with bearer only. Paperclip shows a
  trigger's secret once, when it's made, so this writes its URL (on the
  spec's webhookTriggers.baseUrl, the server block on agents that only n8n
  can reach) and secret straight into the SOPS file the spec names, at the
  trigger's secretsTo, without printing either. A trigger whose URL or
  secret isn't there gets a new secret the same way; n8n's credential for it
  then has to be made again (n8n-apply.py says how).
- never deletes anything, and reads or writes no secret except a webhook
  trigger's, as above. An agent's API key is only checked to come from a
  company secret.

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
import re
import subprocess
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
    ("get", "/api/companies/{companyId}/routines"),
    ("post", "/api/companies/{companyId}/routines"),
    ("patch", "/api/routines/{id}"),
    ("get", "/api/routines/{id}"),
    ("post", "/api/routines/{id}/triggers"),
    ("patch", "/api/routine-triggers/{id}"),
    ("post", "/api/routine-triggers/{id}/rotate-secret"),
]

# A routine's settings and what Paperclip assumes when the spec doesn't say.
ROUTINE_DEFAULTS = {"priority": "medium", "concurrencyPolicy": "coalesce_if_active", "catchUpPolicy": "skip_missed"}
# A declared variable, filled in the way Paperclip stores it.
VARIABLE_DEFAULTS = {"label": None, "type": "text", "defaultValue": None, "required": True, "options": []}
TRIGGER_KINDS = {"schedule", "api", "webhook"}
TRIGGER_KEYS = ("enabled", "cronExpression", "timezone")
# Where a webhook trigger's URL and secret go in SOPS.
SECRETS_TO = re.compile(r"paperclip-triggers/[a-z0-9-]+")

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


def check_routines(spec, spec_dir):
    """Refuse a spec whose routines can't be applied, before signing in."""
    agents = {agent["name"] for agent in spec["agents"]}
    titles = set()
    secrets_to = set()
    for routine in spec.get("routines", []):
        title = routine["title"]
        if title in titles:
            sys.exit(f"routine {title} is in the spec twice")
        titles.add(title)
        if routine["assignee"] not in agents:
            sys.exit(f"routine {title}: its assignee {routine['assignee']} isn't an agent in the spec")
        if not (spec_dir / routine["descriptionFile"]).is_file():
            sys.exit(f"routine {title}: {routine['descriptionFile']} doesn't exist")
        labels = [t["label"] for t in routine.get("triggers", [])]
        if len(labels) != len(set(labels)):
            sys.exit(f"routine {title}: two triggers share a label")
        for trigger in routine.get("triggers", []):
            label = trigger["label"]
            if trigger["kind"] not in TRIGGER_KINDS:
                sys.exit(f"routine {title}: trigger {label} is a {trigger['kind']} trigger; only "
                         f"{', '.join(sorted(TRIGGER_KINDS))} are allowed")
            if trigger["kind"] != "webhook":
                continue
            if trigger.get("signingMode") != "bearer":
                sys.exit(f"routine {title}: webhook trigger {label} is signed with {trigger.get('signingMode') or 'nothing'}; "
                         "only bearer is allowed, so firing it takes the secret n8n holds")
            if not SECRETS_TO.fullmatch(trigger.get("secretsTo", "")):
                sys.exit(f"routine {title}: webhook trigger {label} needs secretsTo, like paperclip-triggers/<name>")
            if trigger["secretsTo"] in secrets_to:
                sys.exit(f"routine {title}: two webhook triggers write to {trigger['secretsTo']}")
            secrets_to.add(trigger["secretsTo"])
    hooks = spec.get("webhookTriggers") or {}
    if secrets_to and not (hooks.get("sopsFile") and hooks.get("baseUrl", "").startswith("https://")):
        sys.exit("the spec has webhook triggers, so it needs webhookTriggers.sopsFile and an https webhookTriggers.baseUrl")


def sops_path(path):
    """paperclip-triggers/fix-ci as sops wants it: ["paperclip-triggers"]["fix-ci"]."""
    return "".join(f'["{part}"]' for part in path.split("/"))


class TriggerSecrets:
    """Webhook triggers' URLs and secrets, in one SOPS file. Neither is ever printed."""

    def __init__(self, spec, spec_dir):
        hooks = spec.get("webhookTriggers") or {}
        self.file = (spec_dir / hooks["sopsFile"]).resolve() if hooks.get("sopsFile") else None
        self.base = hooks.get("baseUrl", "").rstrip("/")
        self.env = {**os.environ, "SOPS_AGE_KEY_FILE": os.environ.get(
            "SOPS_AGE_KEY_FILE", str(pathlib.Path.home() / ".config/sops/age/keys.txt"))}
        self.checked = False

    def readable(self):
        """Stop unless sops can decrypt the file, so a missing key never looks like a missing secret."""
        if self.checked:
            return
        done = subprocess.run(["sops", "decrypt", str(self.file)], env=self.env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if done.returncode != 0:
            sys.exit(f"sops can't decrypt {self.file} with {self.env['SOPS_AGE_KEY_FILE']}, so webhook triggers "
                     f"can't be checked or made: {done.stderr.strip()[:300]}")
        self.checked = True

    def url(self, public_id):
        return f"{self.base}/api/routine-triggers/public/{public_id}/fire"

    def _get(self, path):
        done = subprocess.run(["sops", "decrypt", "--extract", sops_path(path), str(self.file)],
                              env=self.env, capture_output=True, text=True)
        return done.stdout.strip() if done.returncode == 0 else None

    def holds(self, path, public_id):
        """Whether SOPS has this trigger's URL at path, with a secret beside it."""
        self.readable()
        return self._get(f"{path}/url") == self.url(public_id) and bool(self._get(f"{path}/secret"))

    def write(self, path, material, public_id):
        done = subprocess.run(["sops", "set", "--value-stdin", str(self.file), sops_path(path)],
                              input=json.dumps({"url": self.url(public_id), "secret": material["webhookSecret"]}),
                              env=self.env, capture_output=True, text=True)
        if done.returncode != 0:
            sys.exit(f"sops couldn't set {path} in {self.file.name}: {done.stderr.strip()[:300]}\n"
                     "Run this again: the trigger gets a new secret, written the same way.")


def variables(declared):
    """Declared variables by name, with Paperclip's defaults filled in."""
    return {v["name"]: {k: v.get(k, default) for k, default in VARIABLE_DEFAULTS.items()} for v in declared or []}


def trigger_body(trigger):
    body = {"kind": trigger["kind"], "label": trigger["label"], "enabled": trigger.get("enabled", True)}
    if trigger["kind"] == "schedule":
        body.update(cronExpression=trigger["cronExpression"], timezone=trigger["timezone"])
    if trigger["kind"] == "webhook":
        body["signingMode"] = trigger["signingMode"]
    return body


def describe_trigger(trigger):
    if trigger["kind"] == "webhook":
        return f"{trigger['label']}: webhook, its URL and secret to SOPS at {trigger['secretsTo']}"
    return f"{trigger['label']}: {trigger.get('cronExpression', trigger['kind'])}"


def add_trigger(pc, routine_id, trigger, secrets):
    if trigger["kind"] == "webhook":
        # Paperclip shows the secret only now, so make sure it can be kept first.
        secrets.readable()
    made = pc.call("post", f"/api/routines/{routine_id}/triggers", trigger_body(trigger))
    if trigger["kind"] == "webhook":
        secrets.write(trigger["secretsTo"], made["secretMaterial"], made["trigger"]["publicId"])
        print(f"    wrote its URL and secret to SOPS at {trigger['secretsTo']}; scripts/automation/n8n-apply.py "
              "--apply makes n8n's credential for it (delete an older one in n8n first)")


def apply_routines(pc, cid, spec, spec_dir, agents, write):
    if "routines" not in spec:
        return 0
    secrets = TriggerSecrets(spec, spec_dir)
    changes = 0
    have = {}
    for routine in pc.call("get", f"/api/companies/{cid}/routines"):
        have.setdefault(routine["title"], routine)
    agent_name = {a["id"]: name for name, a in agents.items()}

    for routine in spec["routines"]:
        title = routine["title"]
        description = (spec_dir / routine["descriptionFile"]).read_text().strip()
        assignee = routine["assignee"]
        assignee_id = agents.get(assignee, {}).get("id")
        settings = {k: routine.get(k, v) for k, v in ROUTINE_DEFAULTS.items()}
        triggers = routine.get("triggers", [])
        cur = have.get(title)

        if cur is None:
            changes += 1
            when = ", ".join(describe_trigger(t) for t in triggers) or "no triggers"
            print(f"  + routine {title} (for {assignee}, {when})")
            if write:
                if assignee_id is None:
                    sys.exit(f"routine {title}: its assignee {assignee} doesn't exist in Paperclip")
                created = pc.call("post", f"/api/companies/{cid}/routines", {
                    "title": title, "description": description, "assigneeAgentId": assignee_id,
                    "status": "active", "variables": routine.get("variables", []), **settings})
                for trigger in triggers:
                    add_trigger(pc, created["id"], trigger, secrets)
            continue
        if cur.get("status") == "archived":
            print(f"  ! routine {title} is archived in Paperclip (left alone)")
            continue

        notes = []
        patch = {}
        if (cur.get("description") or "").strip() != description:
            patch["description"] = description
            notes.append("description")
        if cur.get("assigneeAgentId") != assignee_id:
            if assignee_id is None and write:
                sys.exit(f"routine {title}: its assignee {assignee} doesn't exist in Paperclip")
            patch["assigneeAgentId"] = assignee_id
            notes.append(f"assignee {agent_name.get(cur.get('assigneeAgentId'), 'nobody')} -> {assignee}")
        for key, value in settings.items():
            if cur.get(key) != value:
                patch[key] = value
                notes.append(f"{key} {show(cur.get(key))} -> {show(value)}")
        stored = variables(cur.get("variables"))
        want = variables(routine.get("variables"))
        if any(stored.get(name) != v for name, v in want.items()):
            patch["variables"] = routine.get("variables", [])
            notes.append("variables " + ", ".join(sorted(n for n, v in want.items() if stored.get(n) != v)))

        listed = cur.get("triggers") or []
        if any(t.get("kind") == "webhook" for t in [*triggers, *listed]):
            # Only the routine itself shows a webhook's publicId and signing mode.
            listed = pc.call("get", f"/api/routines/{cur['id']}").get("triggers") or []
        by_label = {t.get("label"): t for t in listed}
        new_triggers = []
        trigger_patches = []
        rotations = []
        for trigger in triggers:
            old = by_label.get(trigger["label"])
            if old is None:
                new_triggers.append(trigger)
                notes.append(f"new trigger {describe_trigger(trigger)}")
                continue
            if old.get("kind") != trigger["kind"]:
                print(f"  ! routine {title}: trigger {trigger['label']} is a {old.get('kind')} trigger, "
                      f"the spec says {trigger['kind']} (not changed)")
                continue
            body = trigger_body(trigger)
            drift = {k: body[k] for k in TRIGGER_KEYS if k in body and old.get(k) != body[k]}
            if drift:
                trigger_patches.append((old["id"], drift))
                notes += [f"trigger {trigger['label']} {k} {show(old.get(k))} -> {show(v)}" for k, v in drift.items()]
            if trigger["kind"] != "webhook":
                continue
            if old.get("signingMode") != trigger["signingMode"]:
                print(f"  ! routine {title}: webhook trigger {trigger['label']} is signed with "
                      f"{old.get('signingMode')}, the spec says {trigger['signingMode']} (not changed: delete it "
                      "in Paperclip and run this again)")
            elif not secrets.holds(trigger["secretsTo"], old["publicId"]):
                rotations.append((old["id"], trigger["secretsTo"]))
                notes.append(f"trigger {trigger['label']}: a new secret, with its URL, to SOPS at {trigger['secretsTo']} "
                             "(SOPS doesn't have this trigger's)")
        for label, old in by_label.items():
            if label not in {t["label"] for t in triggers}:
                print(f"  ? routine {title}: {old.get('kind')} trigger {label} exists only in Paperclip (left alone)")
        if cur.get("status") != "active":
            print(f"  ! routine {title} is {cur.get('status')} in Paperclip (left alone)")

        if notes:
            changes += 1
            print(f"  ~ routine {title}: " + ", ".join(notes))
            if write:
                if patch:
                    pc.call("patch", f"/api/routines/{cur['id']}", patch)
                for trigger in new_triggers:
                    add_trigger(pc, cur["id"], trigger, secrets)
                for trigger_id, drift in trigger_patches:
                    pc.call("patch", f"/api/routine-triggers/{trigger_id}", drift)
                for trigger_id, path in rotations:
                    rotated = pc.call("post", f"/api/routine-triggers/{trigger_id}/rotate-secret", {})
                    secrets.write(path, rotated["secretMaterial"], rotated["trigger"]["publicId"])
                    print(f"    n8n's credential for {path} now holds the old secret: delete it in n8n, then run "
                          "scripts/automation/n8n-apply.py --apply")
        else:
            print(f"  = routine {title}")

    for title, routine in sorted(have.items()):
        if title not in {r["title"] for r in spec["routines"]} and routine.get("status") != "archived":
            print(f"  ? routine {title} exists only in Paperclip (left alone)")
    return changes


def apply(pc, spec, write, spec_dir=DEFAULT_SPEC.parent):
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

    return changes + apply_routines(pc, cid, spec, spec_dir, agents, write)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="https://paperclip.servicestack.xyz")
    ap.add_argument("--spec", default=str(DEFAULT_SPEC))
    ap.add_argument("--apply", action="store_true", help="make the changes (default: only show them)")
    args = ap.parse_args()

    spec_path = pathlib.Path(args.spec)
    spec = json.loads(spec_path.read_text())
    check_routines(spec, spec_path.parent)
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
        changes = apply(pc, spec, args.apply, spec_path.parent)
        print(f"{changes} change(s) {'made' if args.apply else 'pending'}")
    finally:
        if signed_in:
            try:
                pc.call("post", "/api/cli-auth/revoke-current")
            except SystemExit as err:
                print(f"couldn't revoke this run's board key: {err}", file=sys.stderr)


if __name__ == "__main__":
    main()
