#!/usr/bin/env python3
"""Bring n8n's credentials and workflows in line with hosts/automation.

Uses n8n's public API (/api/v1) with the owner's API key, from
n8n/api-key in secrets/hosts/automation.yaml or N8N_API_KEY, and only for
what the repo names:

- credentials, from hosts/automation/n8n-credentials.json, matched by name.
  Each field's value comes from SOPS, at the path the file gives, or is
  written out as {"literal": ...} when it isn't the secret (a header's
  name). A missing credential is created. n8n never shows a stored value,
  and its public API can't change one (2.39 answers PATCH /credentials/{id}
  with 405), so an existing credential is left alone. To change a secret,
  delete the credential in n8n and run this again; the workflows follow the
  new one.
- workflows, one file each in hosts/automation/workflows/, matched by name.
  A node names its credentials, and this fills in the ids n8n gave them. A
  URL that lives in SOPS, like a Paperclip trigger's (which
  paperclip-apply.py writes there), is written {"sops": "<path>/url"} in a
  parameter named url, and this fills it in. A missing workflow is created,
  and one whose nodes, connections or settings differ is updated. Either way
  it's then published.
- never deletes anything and never prints a secret. It refuses a workflow
  file that carries a credential's id or data, a literal Authorization
  header or a field named like a secret, any value from SOPS, or a SOPS
  path anywhere but a url. --check runs the checks that need neither n8n
  nor SOPS, for the flake check.

It's a dry run unless you pass --apply. SOPS_AGE_KEY_FILE defaults to
~/.config/sops/age/keys.txt, the operator key.

usage:
  scripts/automation/n8n-apply.py [--url https://automation.servicestack.xyz] [--apply]
  scripts/automation/n8n-apply.py --check
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
HOST = ROOT / "hosts/automation"
SOPS_FILE = ROOT / "secrets/hosts/automation.yaml"
API_KEY_PATH = "n8n/api-key"

# What a workflow update may carry; n8n refuses anything else.
WORKFLOW_KEYS = ("name", "nodes", "connections", "settings")
# Parameter names that hold a secret when they hold a literal.
SECRET_NAME = re.compile(r"(?i)(password|secret|token|api[_-]?key)$")
# Credential fields that are the secret itself, so never a literal.
SECRET_FIELD = re.compile(r"(?i)^(value|password|secret|token|api[_-]?key|.*(secret|token|password))$")


class N8n:
    def __init__(self, base, key):
        self.base = base.rstrip("/") + "/api/v1"
        self.key = key

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method.upper())
        req.add_header("X-N8N-API-KEY", self.key)
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

    def every(self, path):
        """Every item of a paged list."""
        items, cursor = [], None
        while True:
            query = {"limit": 250, **({"cursor": cursor} if cursor else {})}
            page = self.call("get", f"{path}?{urllib.parse.urlencode(query)}")
            items += page.get("data") or []
            cursor = page.get("nextCursor")
            if not cursor:
                return items


def sops_value(path, sops_file, env):
    """The value at a/b/c in the SOPS file, never printed."""
    expr = "".join(f'["{part}"]' for part in path.split("/"))
    done = subprocess.run(["sops", "--decrypt", "--extract", expr, str(sops_file)],
                          env=env, capture_output=True, text=True)
    if done.returncode != 0:
        # sops names the path, never the value, when it can't find it.
        sys.exit(f"sops couldn't read {path} from {sops_file}: {done.stderr.strip()[:300]}")
    return done.stdout.strip()


def literal(value):
    return isinstance(value, dict) and set(value) == {"literal"}


def sops_paths(credential):
    """The SOPS paths a credential's fields come from."""
    return [value for value in credential["data"].values() if not literal(value)]


def load(host):
    credentials = json.loads((host / "n8n-credentials.json").read_text())["credentials"]
    names = [c["name"] for c in credentials]
    if len(names) != len(set(names)):
        sys.exit("n8n-credentials.json names a credential twice")
    for credential in credentials:
        for field, value in credential["data"].items():
            if literal(value) and SECRET_FIELD.match(field):
                sys.exit(f"n8n-credentials.json: {credential['name']}'s {field} is the secret, so it comes from SOPS, "
                         "not a literal")
            if not literal(value) and not (isinstance(value, str) and value):
                sys.exit(f"n8n-credentials.json: {credential['name']}'s {field} is a SOPS path or {{\"literal\": ...}}")
    workflows = {}
    for path in sorted((host / "workflows").glob("*.json")):
        workflow = json.loads(path.read_text())
        extra = set(workflow) - set(WORKFLOW_KEYS)
        if extra or set(WORKFLOW_KEYS) - set(workflow):
            sys.exit(f"{path.name}: a workflow file has exactly {', '.join(WORKFLOW_KEYS)} (got {', '.join(sorted(workflow))})")
        if workflow["name"] in workflows:
            sys.exit(f"{path.name}: another file already has the workflow {workflow['name']}")
        workflows[workflow["name"]] = (path.name, workflow)
    return credentials, workflows


def strings(value, where=()):
    """Every (path, key, string) in a JSON value."""
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, str):
                yield where, key, item
            else:
                yield from strings(item, where + (key,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            if isinstance(item, str):
                yield where, index, item
            else:
                yield from strings(item, where + (index,))


def marker(value):
    return isinstance(value, dict) and set(value) == {"sops"}


def markers(value, where=()):
    """Every (path, key, SOPS path) of a {"sops": ...} marker in a JSON value."""
    if isinstance(value, dict):
        for key, item in value.items():
            if marker(item):
                yield where, key, item["sops"]
            else:
                yield from markers(item, where + (key,))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from markers(item, where + (index,))


def url_paths(workflows):
    """The SOPS paths the workflows' url markers name."""
    return sorted({path for _, (_, w) in workflows.items() for node in w["nodes"]
                   for _, _, path in markers(node.get("parameters") or {})})


def resolve(value, values):
    """value with every marker replaced by the SOPS value it names."""
    if marker(value):
        return values[value["sops"]]
    if isinstance(value, dict):
        return {k: resolve(v, values) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, values) for v in value]
    return value


def check(credentials, workflows, secrets=()):
    """Refuse workflow files that carry anything secret."""
    declared = {c["name"] for c in credentials}
    credential_paths = {path for c in credentials for path in sops_paths(c)}
    problems = []
    for name, (file, workflow) in workflows.items():
        for node in workflow["nodes"]:
            for where, key, path in markers(node):
                if where[:1] != ("parameters",) or key != "url" or not str(path).endswith("/url") \
                        or path in credential_paths:
                    problems.append(f"{file}: node {node['name']} takes {path} from SOPS at "
                                    f"{'.'.join(map(str, where + (key,)))}; only a parameter named url may, "
                                    "and only from a path ending in /url")
            for kind, ref in (node.get("credentials") or {}).items():
                if set(ref) != {"name"}:
                    problems.append(f"{file}: node {node['name']} gives its {kind} credential more than a name")
                elif ref["name"] not in declared:
                    problems.append(f"{file}: node {node['name']} names the credential {ref['name']}, "
                                    "which n8n-credentials.json doesn't declare")
            for where, key, text in strings(node.get("parameters") or {}):
                literal = text and not text.startswith("=")
                if literal and isinstance(key, str) and SECRET_NAME.search(key):
                    problems.append(f"{file}: node {node['name']} has a literal value for {'.'.join(map(str, where + (key,)))}")
            for header in _headers(node.get("parameters") or {}):
                if str(header.get("name", "")).lower() == "authorization" and header.get("value"):
                    problems.append(f"{file}: node {node['name']} sets an Authorization header itself; use a credential")
        text = json.dumps(workflow)
        for secret in secrets:
            if secret and secret in text:
                problems.append(f"{file}: holds a value from SOPS")
    if problems:
        sys.exit("refusing these workflow files:\n  " + "\n  ".join(problems))


def _headers(value):
    if isinstance(value, dict):
        if "name" in value and "value" in value:
            yield value
        for item in value.values():
            yield from _headers(item)
    elif isinstance(value, list):
        for item in value:
            yield from _headers(item)


def with_ids(workflow, ids, values):
    """The workflow as n8n stores it: credentials by id and name, URLs from SOPS filled in."""
    nodes = []
    for node in workflow["nodes"]:
        node = resolve(node, values)
        if node.get("credentials"):
            node["credentials"] = {kind: {"id": ids.get(ref["name"]), "name": ref["name"]}
                                   for kind, ref in node["credentials"].items()}
        nodes.append(node)
    return {**workflow, "nodes": nodes}


def differences(want, have):
    """What differs, looking only at what the repo sets."""
    notes = []
    have_nodes = {n.get("name"): n for n in have.get("nodes") or []}
    for node in want["nodes"]:
        cur = have_nodes.get(node["name"])
        if cur is None:
            notes.append(f"new node {node['name']}")
        elif any(cur.get(k) != v for k, v in node.items()):
            notes.append(f"node {node['name']} " + ", ".join(sorted(k for k, v in node.items() if cur.get(k) != v)))
    for name in sorted(set(have_nodes) - {n["name"] for n in want["nodes"]}):
        notes.append(f"node {name} goes")
    if (have.get("connections") or {}) != want["connections"]:
        notes.append("connections")
    cur_settings = have.get("settings") or {}
    if any(cur_settings.get(k) != v for k, v in want["settings"].items()):
        notes.append("settings")
    return notes


def apply(n8n, credentials, workflows, values, write):
    changes = 0

    have = {}
    for credential in n8n.every("/credentials"):
        have.setdefault(credential["name"], credential)
    ids = {name: c["id"] for name, c in have.items()}
    for credential in credentials:
        name = credential["name"]
        data = {field: value["literal"] if literal(value) else values[value]
                for field, value in credential["data"].items()}
        cur = have.get(name)
        if cur is None:
            changes += 1
            print(f"  + credential {name} ({credential['type']}, from {', '.join(sops_paths(credential))})")
            if write:
                ids[name] = n8n.call("post", "/credentials", {"name": name, "type": credential["type"], "data": data})["id"]
        elif cur.get("type") != credential["type"]:
            print(f"  ! credential {name} is a {cur.get('type')} credential, the repo says {credential['type']}: "
                  "delete it in n8n and run this again")
        else:
            print(f"  = credential {name} (n8n can't show its value: after changing it in SOPS, delete it in n8n "
                  "and run this again)")
    for name in sorted(set(have) - {c["name"] for c in credentials}):
        print(f"  ? credential {name} exists only in n8n (left alone)")

    current = {}
    for workflow in n8n.every("/workflows"):
        if not workflow.get("isArchived"):
            current.setdefault(workflow["name"], workflow)
    for name, (file, workflow) in workflows.items():
        want = with_ids(workflow, ids, values)
        cur = current.get(name)
        if cur is None:
            changes += 1
            print(f"  + workflow {name} (from {file}), published")
            if write:
                created = n8n.call("post", "/workflows", want)
                n8n.call("post", f"/workflows/{created['id']}/publish", {})
            continue
        notes = differences(want, n8n.call("get", f"/workflows/{cur['id']}"))
        if notes:
            changes += 1
            print(f"  ~ workflow {name}: " + "; ".join(notes))
            if write:
                n8n.call("put", f"/workflows/{cur['id']}?publishIfActive=true", want)
        if not cur.get("active"):
            if not notes:
                changes += 1
            print(f"  ~ workflow {name}: publish")
            if write:
                n8n.call("post", f"/workflows/{cur['id']}/publish", {})
        elif not notes:
            print(f"  = workflow {name}")
    for name in sorted(set(current) - set(workflows)):
        print(f"  ? workflow {name} exists only in n8n (left alone)")
    return changes


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default="https://automation.servicestack.xyz")
    ap.add_argument("--apply", action="store_true", help="make the changes (default: only show them)")
    ap.add_argument("--check", action="store_true", help="only check the workflow files, with no n8n or SOPS")
    ap.add_argument("--host-dir", default=str(HOST), help=argparse.SUPPRESS)
    ap.add_argument("--sops-file", default=str(SOPS_FILE), help=argparse.SUPPRESS)
    args = ap.parse_args()

    credentials, workflows = load(pathlib.Path(args.host_dir))
    check(credentials, workflows)
    if args.check:
        print(f"{len(workflows)} workflow(s) and {len(credentials)} credential(s) check out")
        return

    env = {**os.environ, "SOPS_AGE_KEY_FILE": os.environ.get("SOPS_AGE_KEY_FILE",
                                                              str(pathlib.Path.home() / ".config/sops/age/keys.txt"))}
    secret_paths = sorted({path for c in credentials for path in sops_paths(c)})
    values = {path: sops_value(path, args.sops_file, env) for path in [*secret_paths, *url_paths(workflows)]}
    empty = [path for path, value in values.items() if not value]
    if empty:
        sys.exit(f"these SOPS values are empty: {', '.join(empty)}")
    # Every value from SOPS, the URLs too, must stay out of the files.
    check(credentials, workflows, values.values())

    key = os.environ.get("N8N_API_KEY") or sops_value(API_KEY_PATH, args.sops_file, env)
    n8n = N8n(args.url, key)
    mode = "applying" if args.apply else "dry run (pass --apply to make these changes)"
    print(f"{args.url}: {mode}")
    changes = apply(n8n, credentials, workflows, values, args.apply)
    print(f"{changes} change(s) {'made' if args.apply else 'pending'}")


if __name__ == "__main__":
    main()
