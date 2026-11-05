#!/usr/bin/env python3
"""Seed Doppler (personal workplace) project lab118-services, config prd.

Copies the notification-stack secrets from the operator SOPS file into
Doppler without ever printing a value: values move from `sops -d` to
`doppler secrets set` through memory and stdin only (never argv or env).

Values are copied unchanged, except the ntfy publisher token of the
`apprise` user. That token was exposed on 2026-10-05, so a new one is
generated and written to both NTFY_AUTH_TOKENS and APPRISE_CONFIG. The old
host keeps its SOPS values.

NEWT_ID and NEWT_SECRET are not in SOPS: paste them at the hidden prompts
(copy them from the Pangolin site you created for lab118-services).

usage:
  DOPPLER_CONFIG_DIR=~/.doppler-personal python3 scripts/lab118/seed-doppler.py <personal-workplace-slug>
"""
import getpass
import json
import os
import secrets
import string
import subprocess
import sys

PROJECT = "lab118-services"
CONFIG = "prd"
REPO = subprocess.run(["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip()
SOPS_FILE = os.path.join(REPO, "secrets", "secrets.yaml")

FROM_SOPS = {
    "ALERTA_SECRET_KEY": '["notifications"]["alerta"]["secret-key"]',
    "ALERTA_ADMIN_USER": '["notifications"]["alerta"]["admin-user"]',
    "ALERTA_ADMIN_PASSWORD": '["notifications"]["alerta"]["admin-password"]',
    "ALERTA_API_KEY": '["notifications"]["alerta"]["api-key"]',
    "NTFY_AUTH_USERS": '["notifications"]["ntfy"]["auth-users"]',
    "NTFY_AUTH_TOKENS": '["notifications"]["ntfy"]["auth-tokens"]',
    "APPRISE_CONFIG": '["notifications"]["apprise"]["config"]',
}
PROMPTED = ["NEWT_ID", "NEWT_SECRET"]


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def run(args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def required_keys():
    layout = json.loads(run(["nix", "eval", "--json", "--file", os.path.join(REPO, "hosts/lab118-services/doppler-secrets.nix")]).stdout)
    keys = set()
    for output in layout["outputs"].values():
        keys.update([output["key"]] if output["format"] == "raw" else output["vars"].values())
    return keys


def sops_value(path):
    try:
        value = run(["sops", "-d", "--extract", path, SOPS_FILE]).stdout
    except subprocess.CalledProcessError:
        die(f"could not decrypt {path} from secrets/secrets.yaml (is SOPS_AGE_KEY_FILE set?)")
    return value.rstrip("\n")


def new_ntfy_token():
    alphabet = string.ascii_lowercase + string.digits
    return "tk_" + "".join(secrets.choice(alphabet) for _ in range(29))


def rotate_apprise_token(tokens, apprise_config):
    entries = [e.strip() for e in tokens.split(",") if e.strip()]
    old = None
    new = new_ntfy_token()
    rotated = []
    for entry in entries:
        parts = entry.split(":")
        if parts[0] == "apprise":
            old = parts[1]
            parts[1] = new
        rotated.append(":".join(parts))
    if old is None:
        die("NTFY_AUTH_TOKENS has no entry for user 'apprise'")
    if apprise_config.count(old) != 1:
        die("APPRISE_CONFIG does not contain the apprise token exactly once; refusing to guess")
    return ",".join(rotated), apprise_config.replace(old, new)


def doppler_set(name, value):
    if not value:
        die(f"{name} is empty")
    subprocess.run(
        ["doppler", "secrets", "set", name, "--project", PROJECT, "--config", CONFIG, "--silent", "--no-interactive"],
        input=value, text=True, check=True, stdout=subprocess.DEVNULL,
    )
    print(f"set {name}")


def main():
    if len(sys.argv) != 2:
        die("usage: seed-doppler.py <personal-workplace-slug>")
    if not os.environ.get("DOPPLER_CONFIG_DIR"):
        die("set DOPPLER_CONFIG_DIR to your personal Doppler config dir (e.g. ~/.doppler-personal)")
    os.environ.setdefault("SOPS_AGE_KEY_FILE", os.path.expanduser("~/.config/sops/age/keys.txt"))

    workplace = json.loads(run(["doppler", "me", "--json"]).stdout)["workplace"]
    if workplace["slug"] != sys.argv[1]:
        die(f"logged-in Doppler workplace is '{workplace['slug']}' ({workplace['name']}), expected '{sys.argv[1]}'")
    run(["doppler", "configs", "get", CONFIG, "--project", PROJECT, "--json"])
    print(f"Doppler workplace: {workplace['name']} ({workplace['slug']}), project {PROJECT}, config {CONFIG}")

    values = {name: sops_value(path) for name, path in FROM_SOPS.items()}
    values["NTFY_AUTH_TOKENS"], values["APPRISE_CONFIG"] = rotate_apprise_token(values["NTFY_AUTH_TOKENS"], values["APPRISE_CONFIG"])
    for name in PROMPTED:
        values[name] = getpass.getpass(f"Paste {name} from the Pangolin site (input hidden): ").strip()

    missing = required_keys() - values.keys()
    if missing:
        die(f"layout requires keys this script does not provide: {sorted(missing)}")

    for name in sorted(values):
        doppler_set(name, values[name])

    names = set(json.loads(run(["doppler", "secrets", "--project", PROJECT, "--config", CONFIG, "--only-names", "--json"]).stdout))
    absent = required_keys() - names
    if absent:
        die(f"Doppler is still missing: {sorted(absent)}")
    print(f"OK: all {len(required_keys())} required keys are present in {PROJECT}/{CONFIG}.")
    print("The apprise ntfy token was regenerated (the old one was exposed); nothing was printed.")


if __name__ == "__main__":
    main()
