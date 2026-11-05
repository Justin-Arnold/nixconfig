# workbench

workbench is where the agents' work runs: a NixOS VM on the Proxmox cluster
that the Hermes agents on the agents VM log in to over ssh. Their terminal
and file tools act here, so this is where repos get cloned, code gets
written and tests run.

It's the other half of the agents VM's rule. Credentials live where
generated code never runs, so this host holds none of them: no model
logins, no Paperclip keys, no SOPS keys for anything else. The one thing
worth taking is a GitHub token that can push `agent/**` branches to the
repos the agents work on.

It's also disposable. Work lives on pushed branches, so nothing here is
backed up, and rebuilding it loses nothing that matters.

## At a glance

| | |
|---|---|
| VM | Proxmox, 8 vCPU (`host`), 16 GB, 200 GB on `local-lvm` on `proxmox4`, MAC `02:01:18:00:00:07`, no HA |
| Address | `10.0.0.153` (DHCP reservation) |
| Agents | `agent-engineer` (uid 3302), `agent-reviewer` (3304) and `agent-infra` (3305), for those agents on the agents VM |
| Login | `ssh workbench` as `justin`, key only (the Mac Mini key). Agents log in from the agents VM only. Root has no SSH. |
| Console | Proxmox console, root password from SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/workbench.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Backups | none |

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/workbench/configuration.nix` | The host: SOPS, nix garbage collection, the Beszel agent, and the exposure assertions. |
| `hosts/workbench/agents.nix` | The agent users, their ssh limits, rootless Podman, the egress filter, git and the GitHub token, and the worktree timer. |
| `hosts/workbench/agent-worktree.sh` | Makes or finds an agent's worktree for a piece of work. |
| `hosts/workbench/agent-review.sh` | Makes or moves a read-only worktree at a pull request's head, for the reviewer. |
| `hosts/workbench/prune-worktrees.sh` | Removes finished worktrees. |
| `hosts/workbench/eval-test.nix` | Example values for the flake checks, not used by the real host. |
| `infra/terranix/hosts/workbench.nix` | The VM, its node and storage. |
| `hosts/agents/agents.nix` | The other end: the engineer's, reviewer's and infra's ssh terminals, and workbench's host key. |
| `scripts/flake-check.sh` | What infra and the reviewer run to check nixconfig here: every host evaluates and every flake check builds. |
| `modules/roles/agent-egress.nix` | The outbound filter, shared with the agents VM. |
| `scripts/workbench/post-install-check.sh` | Read-only health report. |

## Why it isn't HA

Everything else in the agents setup is built to move between nodes. This
host isn't, on purpose. It has no state worth recovering, and builds, the
nix store and container images churn through disk in a way that's slow over
NFS and would fill the NAS. So the disk sits on `proxmox4`'s local storage,
the CPU type is `host` so builds get every instruction the node has, and if
the node goes down the agents lose their terminal until it's back or the VM
is rebuilt somewhere else.

## How the agents get in

A Hermes agent with an ssh terminal logs in as `agent-<name>` with its own
key, `hermes/<name>/ssh-key` in the agents VM's SOPS file. Each command is
its own `ssh … bash -c` over one shared connection, with no pty. Its file
tools work the same way, through shell commands on this host.

The key is installed as `restrict,from="10.0.0.152" <key>`: it works only
from the agents VM and allows no port, agent or X11 forwarding, no pty and no
`~/.ssh/rc`. sshd says the same for every `agent-*` user in a `Match` block,
and `AllowUsers` lets in only `justin` and the agent users. The agents VM
pins this host's key in each agent's `known_hosts`, so a changed key stops
the connection instead of being learned.

Until an agent's public key is set in `workbench.agents` in `agents.nix`, its
user exists but can't log in, and evaluation warns about it. The agents'
side switches on when workbench's host key is set in
`hosts/agents/agents.nix`.

Hermes copies the agent's skills to `~/.hermes` here and brings back what
changed. It would copy credential files too if a skill or
`terminal.credential_files` asked for them; the Hermes role refuses a build
that sets `credential_files` or `env_passthrough`.

## What an agent can do here

An agent's commands run as its own user, with a home only it can read. It
isn't in `wheel`, has no sudo rules, and isn't a trusted user of the nix
daemon, so it can't turn off the build sandbox or add binary caches. It can
use nix (`nix shell`, `nix develop`, `nix build`), and rootless Podman for
test services. There's no Docker and no container socket.

On the network it reaches the Internet and nothing in the LAN, through the
same filter as the agents VM (`inet agent-egress`). Nix's build users are
filtered too, by their group, because they fetch sources for the agents'
builds. The daemon itself, which pulls from the binary caches, isn't. DNS
goes through systemd-resolved on loopback.

Nix garbage collection runs weekly and drops anything older than a week.

## GitHub

The agents push as a separate machine account, never as Justin, with a
classic token that has the `repo` scope and nothing else. A fine-grained
token can't act on repos where its account is only a collaborator, which is
how the machine account gets in. Leaving out the `workflow` scope means
GitHub refuses any push that touches `.github/workflows`, so an agent can't
change what CI runs.

The token's reach comes from outside the repo. The machine account is a
collaborator with Write access on nixconfig and `Justin-Arnold/agent-scratch`
and nothing else. Each repo has the two rulesets in
`scripts/workbench/github-rulesets/`: only the repo's admin (Justin) can
create, update, delete or force-push any branch outside `agent/**`, or any
tag. So an agent can push its branches and open pull requests, and can't
touch the default branch, merge, or change settings.

The exclusion is written `refs/heads/agent/**/*`. GitHub matches these
patterns with Ruby's `File.fnmatch` and `FNM_PATHNAME`, where `*` stops at a
slash and `**` only spans folders when a `/` follows it, so `agent/**` would
cover `agent/<name>` and not `agent/engineer/<name>`, the only kind of branch
`agent-worktree` makes. The `provisioning` check holds the file to that
pattern, and the smoke test's `rulesets` stage compares agent-scratch's live
rulesets with the files.

Rulesets on a private repo need GitHub Pro on the owning account, which is
why Justin's account has it. On Free they'd only apply to nixconfig, which is
public.

agent-scratch is a private repo where nothing matters. It's where the agents
get practice tasks before real ones, and where the end-to-end smoke test
files issues and expects a pull request back.

On this host the token is `github/token`, readable by the `agents` group.
git gets it from a credential helper in `/etc/gitconfig` for
`https://github.com`, and `gh` is a wrapper that passes it as `GH_TOKEN`.
Commits are authored as the machine account (`flickering-text-387`). `git
push` sends a branch to the branch of the same name and creates it on the
first push.

Agent commits never reach a default branch as they are. GitHub's squash
merge credits the pull request's author, which would be the machine account,
so a pull request is landed by squashing its branch locally into a commit of
Justin's own and pushing that, then closing the pull request with a pointer
to the commit. The default branch only has Justin's commits, and the pull
request keeps the agent's history.

`scripts/workbench/land-pr.sh <number>`, run in a checkout of the repo, does
that in a throwaway worktree, so the checkout's own branch and files stay as
they are. It opens the editor with the title and the agent's commits, shows
the commit before pushing, and deletes the branch once the pull request is
closed. It refuses a pull request whose branch moved while it ran, and one
that doesn't apply cleanly to its base, which the agent then rebases.

Until `workbench.github` is set in `agents.nix`, there's no token, no
credential helper and no `gh`, agents can only clone public repos, and
evaluation warns about it.

## Worktrees

`agent-worktree <owner/repo> <name>` prints the path of a worktree for a
piece of work, on the branch `agent/<agent>/<name>`. Each repo is fetched once
per agent into `~/repos/<owner>/<repo>.git` and worktrees go in
`~/work/<repo>/<name>`. A new branch starts from the repo's default branch,
one that's already on GitHub is checked out where it was, and asking again
for the same name gives the same path.

`agent-review <owner/repo> <pr>` is the reviewer's: it fetches the pull
request's head into the same bare repo and prints a detached worktree at it,
`~/work/<repo>/pr-<n>`. There's no branch, so nothing to push, and running it
again moves the worktree to the latest head unless tracked files were
changed there.

## Checking nixconfig here

`nix flake check` fails on nixconfig while the legacy hosts (checkmk, gitea,
onepassword-connect, omada-controller, parallels, pr-previews) don't
evaluate, so infra and the reviewer run `scripts/flake-check.sh` from a
worktree instead:
`eval` evaluates every other NixOS host, and `checks` builds every flake check
for this system, one by one, with a line each and a summary. They're separate
because Hermes stops a terminal command after 600 seconds. Nothing builds a
host here: CUDA for inference would compile from source, since the agents
can't add binary caches. darwin isn't checked anywhere but the Mac.

`prune-worktrees.timer` runs daily. It removes worktrees nobody touched for
two weeks, with their local branches, but only when everything in them is
committed and on GitHub. A landed branch counts, since GitHub keeps a pull
request's commits under `refs/pull/<n>/head` after the branch is deleted. It
lists the rest in its journal and leaves them.

## Secrets

`secrets/hosts/workbench.yaml` is encrypted to the host's own age key and the
operator key, nothing else. On macOS, edit it with
`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/workbench.yaml`.

| Key | What |
|---|---|
| `root/console-password-hash` | `mkpasswd -m yescrypt` |
| `beszel/agent-token` | the hub's universal token |
| `github/token` | the machine account's classic token, `repo` scope only. Needed once `workbench.github` is set. |

The agents' ssh private keys aren't here. They're in the agents VM's file,
and only their public halves are in `agents.nix`.

The host key is installed by `nix run .#install` from `HOST_AGE_KEY_FILE`
(`hostAgeKey = true` in `infra/terranix/default.nix`), as on agents. Until
`secrets/hosts/workbench.yaml` exists, the real host fails to build with a
message saying so, and so does `nix flake check`.

## Outside the repo

- An OPNsense DHCP reservation for `02:01:18:00:00:07` at `10.0.0.153`.
- The GitHub machine account, its collaborator invites to nixconfig and
  agent-scratch, and the two rulesets on each.
- The Beszel hub entry for this host.

## Monitoring

Beszel's agent reports the host. There's no Kuma monitor: nothing here
serves anything, and when it's down the engineer's, reviewer's and infra's
runs fail in Paperclip.

## Operations

Rebuilding means `nix run .#provision -- workbench` with `HOST_AGE_KEY_FILE`
and `SSH_PRIVATE_KEY_PATH` set, and nothing to restore. A new install gets a
new ssh host key, so `workbenchHostKey` in `hosts/agents/agents.nix` changes
too, and agents switch after.

An agent's runaway processes or containers are its own:

```sh
sudo loginctl terminate-user agent-engineer
sudo -u agent-engineer podman system prune --all
```

## Known limits

- The token lets anyone holding it push `agent/**` branches and open pull
  requests on the two repos. Generated code runs as the same users that can
  read it, so a prompt-injected agent could send it somewhere. The rulesets
  are what limit the damage.
- A classic token can't be limited to repos, so it can also open issues,
  pull requests and comments on any public repo as the machine account.
  Only a GitHub App's installation tokens could narrow that, and they expire
  hourly.
- Rootless Podman images and containers aren't pruned automatically.
- The filter knows the LAN by its private IPv4 ranges and IPv6's local ones;
  a routed IPv6 LAN prefix would need adding.

## Related

- `docs/agents/REFERENCE.md`: Paperclip and the Hermes agents that log in
  here.
- `readme.md`: the provisioning commands.
