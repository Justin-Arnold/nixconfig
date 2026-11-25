# The agents' repos on forge: a plan, not built

What moving the agents' repos from GitHub to forge would take, and what it
would cost. Nothing here is built. Decide before any of it is.

## Today

- The engineer, the reviewer and infra work on workbench as `agent-<name>`
  and push to GitHub as one machine account, with a classic token (`repo`
  scope only) behind git's credential helper and a `gh` wrapper
  (`hosts/workbench/agents.nix`).
- That account is a collaborator on two repos: nixconfig (public) and
  `agent-scratch` (private). Rulesets keep it to `agent/**` branches; only
  you merge, with `scripts/workbench/land-pr.sh`.
- CI is GitHub Actions (`check.yml`). Its `workflow_run` and `pull_request`
  deliveries go through `intake.lab118.xyz` and the tunnel to n8n, which
  raises LandReady or CIStuck and starts the Fix CI routines, and sweeps
  GitHub's API every 30 minutes for missed deliveries
  (`02. Areas/Homelab/Hosts/automation.md` in Justin's vault, "GitHub deliveries").
- The Review and Fix CI routines (`scripts/agents/paperclip-spec.json`,
  `scripts/agents/routines/`) and the agents' souls drive `gh`. The lab tools
  read GitHub with `observe/github-token`.
- workbench's egress allows the Internet and nothing in the LAN
  (`roles.agentEgress`), and so does the agents host's.

## What it would take

### An account per agent, with no way to the vault

- A Forgejo user per agent that pushes (engineer, reviewer, infra), each an
  ordinary user, never an admin, made with `forge-admin user create`. The
  coordinator and researcher, which only read GitHub today, would each need
  a read-only account or a token of their own.
- The agents' repos in an organization of their own (say `lab`), with a team
  per access level. The vault stays a private repository of yours with no
  collaborators, so no agent account can see it, list it or push to it.
- A key or token per agent. SSH keys would be new keys on workbench, one per
  `agent-<name>` user, in `secrets/hosts/workbench.yaml`. Forgejo tokens are
  per user with scope categories, not per repository, so what a token
  reaches is what its account reaches.
- `GLOBAL_TWO_FACTOR_REQUIREMENT = all` covers machine accounts too. Check
  whether Forgejo 15 still lets an account without a second factor use SSH
  and tokens. If it doesn't, either enroll TOTP on each machine account once
  and throw the secret away, or require it only for admins (`admin`).
- Branch protection in place of the rulesets: a rule for `agent/**` that the
  agents' team may push to, and a lower-priority rule for everything else
  with only you on the push list. Check that Forgejo 15's rule priorities and
  glob patterns can say "everything except `agent/**`", as the GitHub
  exclusion does today.

### Egress from workbench to forge

- `roles.agentEgress.allow.forge = { address = "10.0.0.157"; tcpPorts = [ 22 443 ]; users = [ ... ]; }`
  on workbench, for the agents that push, and on the agents host for any
  agent that reads repos from there.
- forge's firewall already accepts the whole LAN, so nothing changes there.
  workbench would resolve `git.lab118.xyz` through AdGuard, or the agents'
  remotes would name the address.

### What the routines lose without GitHub

- **CI.** forge runs none, by your decision. With no CI there's no
  `workflow_run`, so no LandReady, no CIStuck, and nothing for the two Fix CI
  routines to fix; `land-pr.sh` would have no checks to wait for. The agents
  would run `scripts/flake-check.sh` on workbench before pushing, and you'd
  read its output rather than a green check.
- **Deliveries.** forge can send webhooks, but `forgejo.service` has no
  network on purpose. Giving it a path to n8n on automation
  (`10.0.0.155:443`) means opening its sandbox, and n8n's `github` workflow
  checks GitHub's signature and payload, so it would need a second workflow
  for Forgejo's. And it would still only carry pull-request events.
- **`gh`.** It only talks to GitHub. The souls, the Review and Fix CI
  routine texts, the reviewer's deny list (`gh pr create*`, `gh pr edit*`),
  the `gh` wrapper and `land-pr.sh` would move to `tea` or `fj` (Forgejo's
  CLI) or plain API calls.
- **The lab tools.** `observe/github-token` and what reads GitHub with it
  would need a Forgejo source next to it.
- **The smoke test.** Its `rulesets` and `route` stages test GitHub.

### nixconfig itself

nixconfig is public on GitHub, and its review and CI loop is the one above.
Moving the agents' work on nixconfig to forge means either moving nixconfig
off GitHub or mirroring it there, and you've ruled out mirrors. So for now
the move fits `agent-scratch` and any new private project, not nixconfig.

## The cost to the vault

Today no agent has an account on forge, and the vault's isolation rests on
the network: the agents can't reach forge at all. With agent accounts and
egress to forge, the agents could reach the same Forgejo that holds the
vault's history, and its isolation would rest on Forgejo's permission checks
alone. One authorization bug in Forgejo would be enough to expose the vault.

If the agents' repos move, the safer layout is a second Forgejo for them,
on its own VM (the NixOS module runs one instance per host), so the vault's
forge stays one no agent can reach. That's another VM to run and back up,
and it's what I'd recommend over sharing this one.

## A possible order, if you want it

1. Decide: share forge, or a second forge for the agents.
2. Move `agent-scratch` first and run the smoke test's issue-to-pull-request
   path there, with `tea` in place of `gh`.
3. Move the routine texts and souls off `gh`, for the repos on forge only.
4. Leave nixconfig on GitHub.
