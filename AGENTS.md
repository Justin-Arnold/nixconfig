# For AI tools working in nixconfig

nixconfig is Justin's NixOS flake: his desktop, and the lab's hosts on
Proxmox and Contabo. The repo is public, so nothing private goes in it: no
secret values, and nothing copied from Justin's vault.

## Where things are written down

- What each part does is in the code and its comments. A host is
  `hosts/<host>/`, its VM `infra/terranix/hosts/<host>.nix`.
- Everything else about a host is in Justin's Obsidian vault, one note per
  host at `02. Areas/Homelab/Hosts/<host>.md`: how it's reached, its secrets
  (their names and how to make them, never the values), backups, install and
  recovery steps, settings made by hand outside this repo, decisions, limits
  and gotchas. `02. Areas/Homelab/Lab Flows.md` shows how the hosts fit
  together. The Hermes agents reach the vault through their notes tools;
  Claude Code and Codex find its folder in their own global instructions.
  Follow the vault's own `AGENTS.md` when you write to it.
- Read the host's note before you change the host.
- When a change makes a host's note wrong (a secret's name, a backup, an
  install step, something set by hand), update the note in the same piece of
  work. The note isn't part of the pull request, so no review will catch it.
- `docs/` keeps only what isn't about one host, like the desktop's theming.

## Checking a change

Flakes only see files git knows about, so add new files with `git add -N`
first. Then run `scripts/flake-check.sh eval` and `scripts/flake-check.sh
checks`, as two commands; both take a list of hosts or checks to narrow them.
