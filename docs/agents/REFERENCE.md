# agents

agents is the lab's agent orchestration host: a NixOS VM on the Proxmox
cluster that runs Paperclip on PostgreSQL. Paperclip is the one place that
knows what work exists: issues and who holds them, goals, routines,
approvals, budgets and an activity log of every change. Agents are its
employees and get woken to do their part.

The host is built around one rule: credentials live where generated code
never runs. This VM holds Paperclip's secrets and the model logins of the
Hermes agents, and it never executes what an agent writes. That happens on a
separate execution host.

## At a glance

| | |
|---|---|
| VM | Proxmox, 4 vCPU (`x86-64-v2-AES`), 12 GB, 80 GB on `nas-shared`, MAC `02:01:18:00:00:06`, HA resource |
| Paperclip | `https://paperclip.servicestack.xyz` (2026.1023.0, official image pinned by digest, under Podman) |
| Database | PostgreSQL 17 from nixpkgs, socket and localhost only |
| Agents | Hermes v0.22.5: `coordinator`, `engineer`, `researcher`, `reviewer`, `infra`, one process each, API servers on `127.0.0.1:8642` to `8646` |
| Models | Codex for the coordinator, engineer and infra, with Claude Opus 5.5 as their last fallback; Claude Opus 5.5 for the reviewer, with Sonnet 5.5 and Codex behind it; the lab's GPU (`local` on inference) for the researcher, with Codex behind it, and for every agent's session titles and memory review |
| Tools from outside | Jev, TypeSafe's decision model, as every agent's `decide` tool |
| Login | `ssh agents` as `justin`, key only (the Mac Mini key). Root has no SSH. |
| Console | Proxmox console, root password from SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/agents.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Backups | Nightly at 03:15, NFS share on the NAS, age-encrypted, Kuma push monitor |

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/agents/configuration.nix` | The host: users, SOPS, Podman, Paperclip, the Beszel agent, and the exposure assertions. |
| `hosts/agents/endpoints.nix` | ACME (Porkbun DNS-01), the nginx vhost and its allow-lists. |
| `hosts/agents/nginx/paperclip-guard.conf` | The locations that keep Paperclip's MCP endpoint and public routine webhooks unreachable. |
| `hosts/agents/backup.nix` | The NFS mount and what gets backed up. |
| `hosts/agents/agent-watch.nix`, `hosts/agents/agent-watch/` | The timer that turns Paperclip's state into Alerta alerts, and its test against fakes. |
| `hosts/agents/eval-test.nix` | Example values for the flake checks, not used by the real host. |
| `infra/terranix/hosts/agents.nix` | The VM, its storage, CPU type and HA resource. |
| `hosts/agents/agents.nix` | The Hermes agents, their models, which ones have a Paperclip key, and what they may reach in the LAN. |
| `hosts/agents/souls/` | Each agent's SOUL.md: its job and its limits. |
| `modules/roles/paperclip.nix` | Paperclip under Podman, its database, the key guard and the health watch. |
| `modules/roles/hermes-agents.nix` | One Hermes unit per agent, built from upstream's own module helpers, and the assertions that keep them shell-free. |
| `modules/roles/hermes-agents/paperclip-mcp/` | Paperclip's MCP server, pinned by a lockfile to the Paperclip release. |
| `modules/roles/hermes-agents/jev-mcp/` | The Jev MCP server (`server.py`), its package and its test against a fake TypeSafe API. |
| `modules/roles/agent-egress.nix` | The outbound filter that keeps the agents off the LAN. |
| `modules/roles/sqlite-backup.nix` | Backups, including the PostgreSQL dumps. |
| `scripts/agents/post-install-check.sh` | Read-only health report. |
| `scripts/agents/paperclip-apply.py`, `paperclip-spec.json` | Paperclip's company setting, labels and agents as a spec, applied through its API. |
| `scripts/agents/tests/` | A fake Paperclip that `paperclip-apply.py` is tested against in the `provisioning` check. |
| `scripts/agents/smoke-e2e.py` | The end-to-end smoke test: real issues for the agents, checked against GitHub, workbench and Alerta. |

## How it's reached

It works like the dashboard. In the LAN and over the road-warrior VPN,
AdGuard rewrites `paperclip.servicestack.xyz` to the VM, and nginx serves it
with a Let's Encrypt certificate from Porkbun DNS-01. From anywhere else the
name resolves to Pangolin, which asks for SSO and comes in through the home
site's Newt (`10.0.0.72`). Paperclip's own login applies on both paths.

Agents on other hosts use the LAN path for the API, so the API works when the
WAN or Pangolin is down.

| Path | Who may use it | Goes to |
|---|---|---|
| `/api/health` | LAN, VPN, the tunnel (Kuma) | Paperclip's health check |
| `/mcp`, `/mcp/*`, `/.well-known/*` | nobody | 404 |
| `/api/routine-triggers/public/*` | nobody yet | 404 |
| everything else | LAN (Pangolin included), VPN | Paperclip, `127.0.0.1:3100` |
| unknown names, bare IP | nobody | no certificate, no content |

`/mcp/paperclip` is Paperclip's experimental MCP endpoint for outside
assistants acting as a signed-in person. It's off in Paperclip, and nginx
keeps it unreachable regardless. Routine webhooks are where outside systems
fire routines. A trigger can be created with no authentication, so they stay
closed until a server block is made for a specific sender, such as the alert
pipeline over the tunnel.

lab118-services resolves the name through lab DNS over the tunnel
(`labDomains` in `hosts/lab118-services/configuration.nix`), not through
public DNS, because Pangolin's SSO would stop Kuma's check.

The firewall opens TCP 22, 80 and 443 and nothing else. Paperclip shares the
host's network and listens on 127.0.0.1, so nothing is published past the
firewall. PostgreSQL listens on its socket and on localhost. The assertions
in `configuration.nix` and `endpoints.nix` fail the build if any of that
changes, and `.#checks.<system>.agents-exposure-guards` proves they fire.

### DNS and router settings this depends on

These live outside the repo:
- An AdGuard rewrite for `paperclip.servicestack.xyz` to the VM's address.
- AdGuard's rewrite for `inference.servicestack.xyz`, which the agents use to
  reach the GPU host.
- An OPNsense DHCP reservation for `02:01:18:00:00:06`.
- A `WG_LAB118` rule passing TCP 443 from `10.118.0.1` to the VM, for Kuma's
  check.
- Pangolin: a resource on the home site, `paperclip.servicestack.xyz`,
  targeting `https://<the VM's address>:443` with the TLS server name set to
  `paperclip.servicestack.xyz`, and SSO on.

## Paperclip

The role is `modules/roles/paperclip.nix`. Things worth knowing:

- It runs the official image under Podman as UID 3100 from the first
  process on, so the image's entrypoint never runs as root or chowns
  anything. It has no capabilities, `no-new-privileges`, a 4 GB memory limit
  and a 2048-process limit.
- The mode is `authenticated` with `private` exposure. `local_trusted`, the
  default for a fresh install, treats every request as the admin, and had a
  DNS-rebinding RCE.
- Telemetry, the announcements feed and Paperclip's own hourly database
  dumps are off. The nightly backup covers the database.
- `/var/lib/paperclip` is `/paperclip` in the container: instance config,
  attachments and agent home files.
- Secrets reach it through `paperclip.env`, a root-only file sops-nix
  renders, and the master key through a read-only bind mount. They're
  visible in `podman inspect`, which only root can run, and never in the Nix
  store.
- The master key encrypts every secret stored in Paperclip. Before every
  start, the key guard checks it's 64 hex characters and compares its sha256
  with `/var/lib/paperclip/.master-key.sha256`, which is written on first
  start. A different key stops Paperclip instead of letting it start with
  secrets it can't read.
- The database role's password is set from SOPS by `paperclip-db-password`
  before every start, so the value in SOPS is always the one that works.
- systemd restarts the container whenever it stops. `paperclip-health-watch`
  also restarts it when `/api/health` fails three checks in a row, at most
  once per 15 minutes and never in the first 15 minutes after a start, when
  migrations may still be running.

Paperclip's local adapters (`claude_local`, `codex_local`, `hermes_local`,
`process`) run agent CLIs inside this container with the server's own
privileges, with their permission prompts bypassed by default. They could
read the database credentials. Agents use the remote adapters instead:
`hermes_gateway` (HTTP to a Hermes API server) and `openclaw_gateway`
(WebSocket to an OpenClaw gateway). Nothing in the image is logged in to a
model provider, and nothing should be.

### First start

A fresh authenticated instance is invite-only. The server prints a one-time
first-admin invite URL in its log at first start:

```sh
sudo journalctl -u podman-paperclip --no-pager | grep -iE 'invite|board-claim'
```

Accepting it means creating an account, so a fresh instance needs
`roles.paperclip.signUp.enable` on until the board is claimed. It's off by
default, and off here since the board was claimed on 2026-11-02. Nobody can
create an account while it's off, which is what a single-user instance wants.

### Budgets and providers

Budgets work per company, agent and project, per calendar month, and stop a
scope at 100%. They only limit priced usage. Every `hermes_gateway` run is
recorded as unpriced, whether it ran on Codex or on the local model, so none
of them count, and the local model needs no price. Unpriced usage is only
blocked under a hard-stop budget whose `unpricedUsagePolicy` is `block`; a
hard-stop budget for these agents needs it set to `allow`.

## Hermes agents

Each agent is its own Hermes process (`hermes-<name>.service`), running as
its own user with its own state in `/var/lib/hermes-<name>`. Upstream's
NixOS module runs only one instance, so the role builds each unit from that
module's helpers in the pinned flake input; config.yaml, .env and SOUL.md come
out the way upstream renders them.

Paperclip and an agent talk both ways without a shell on this host:
- Paperclip wakes an agent with the `hermes_gateway` adapter, over HTTP to
  its API server on loopback. The adapter's API key is that agent's
  `API_SERVER_KEY`.
- The agent reads and updates its issues through Paperclip's MCP server,
  which Hermes starts over stdio with the agent's own Paperclip key. Only an
  allow-list of its tools is registered: no raw API requests, no approval
  decisions, no workspace service control. An agent has no Paperclip tools
  until its name is in `withPaperclipKey` in `agents.nix`.
- Paperclip refuses an agent's changes without the id of the run they belong
  to. The upstream MCP server only reads one when it starts, and an agent's
  server outlives its runs, so the package starts from `run-id.mjs`, which
  gives every tool a `paperclipRunId` argument. The agent copies it from the
  Run ID in its wake prompt.

What an agent can do on a machine depends on its terminal backend. Without
one, the terminal, file and code execution toolsets are switched off, because
they'd act on this VM. The engineer, reviewer and infra get the terminal and
file toolsets with an ssh backend on workbench, each logging in as
`agent-<name>` with `hermes/<name>/ssh-key`, once workbench's host key is set
as `workbenchHostKey` in `agents.nix` (`docs/workbench/REFERENCE.md`). Browser,
computer use, cron, kanban, outside connections and chat platforms are off
for everyone.

On the network, an agent reaches the Internet and this VM's own services, and
nothing else in the LAN: not the NAS, Proxmox, OPNsense or AdGuard's admin
page. An nftables table (`inet agent-egress`) matches every socket an agent's
user owns, MCP servers and ssh included, and refuses private, link-local and
multicast addresses. A refusal fails at once rather than timing out, and
shows up in `journalctl -k` as `agent-egress refused:` with the uid. A LAN
service an agent needs goes in `roles.agentEgress.allow` in `agents.nix`, one
address and its ports, optionally for named agents only: every agent may
reach inference on 443, and the agents with a terminal there reach ssh on
workbench. Hermes' own `allow_private_urls: false` refuses
the same addresses in its web tools; the filter is what holds if something
gets past that. Turning it on moved the whole firewall to nftables, so its
rules are in `nft list ruleset`, not iptables.

Dangerous commands need approval (`approvals.mode: manual`), and nobody can
give one. Paperclip starts runs through `/v1/runs`, which tells Hermes a
client could answer, but Paperclip's adapter never does, so a flagged command
is denied when `approvals.timeout` runs out, after 5 seconds rather than the
default 300. The `approvals.deny` globs (sudo, force pushes, merges,
switches, deletes) are refused at once and hold even under `--yolo`. An agent
can have more of its own (`extraDenyCommands`): the reviewer can't push, or
create, edit, close or ready a pull request. Hermes flags `bash -c`, `sh -c`
and `python3 -c` too, since the deny globs can't see inside them; the SOUL.md
of every agent with a terminal says to run commands directly. config.yaml,
.env and SOUL.md belong to root, so an agent can read
them but not change them, and Hermes runs managed, so it refuses to rewrite
its own config. The assertions in the role refuse a build that opens any of
this up; `agents-exposure-guards` proves they fire.

Every agent logs in to Codex with its own ChatGPT device code, so one agent's
token refresh can't sign the others out. `hermes-agent` runs the CLI as an
agent, against its state:

```sh
sudo hermes-agent coordinator auth add openai-codex
sudo systemctl restart hermes-coordinator
```

The ChatGPT account decides which Codex models it gets, and OpenAI retires
names, so a model that isn't offered fails the run with HTTP 400 ("not
supported when using Codex with a ChatGPT account"). `sudo hermes-agent
<name> model` lists what the account offers; leave the picker without
choosing, because the model is set in `agents.nix`. Each agent there has a
fallback a generation back, and Hermes switches to it when a run fails on the
first.

In Paperclip, an agent is a `hermes_gateway` hire with the Hermes API base
URL `http://127.0.0.1:<port>` and its `API_SERVER_KEY`, which Paperclip keeps
as an organization secret. The session key strategy defaults to `issue`, so
one task's memory doesn't bleed into another's, and timed heartbeats start
off. The first hire becomes the CEO and later ones report to it, so the
coordinator goes first. Paperclip stops a run that's still going after the
adapter's `timeoutSec`, 600 seconds unless the spec says otherwise, and
marks the issue blocked. The reviewer and infra get 2400, because nixconfig's
checks alone take longer than ten minutes on workbench. A command the agent
started in the background keeps running there after its run is stopped.

Hermes logs to `logs/gateway.log` and `logs/errors.log` under the agent's
`.hermes`, not to the journal. When the API server can't start, the gateway
keeps running and the unit stays active, and for a rejected key or a port
that's taken it doesn't try again. The health report prints those log lines
for any agent whose `/health` doesn't answer. Each gateway also listens on a
random loopback port for Hermes' own session clients. That API wants a token
made at each start or a ticket from a socket only the agent's user can open,
so the other agents can't use it.

### Models

Each agent has a main model, fallbacks Hermes moves to when a run fails on
it, and models for its side tasks, chosen for its job. The coordinator,
engineer and infra run on Codex, fall back a Codex generation, and then to
Claude Opus 5.5 (`claude-opus-5-5`). The reviewer runs on Claude Opus 5.5 with
high reasoning effort, so code is reviewed by a different model family from
the one that wrote it, and falls back to Sonnet 5.5 and then Codex. The
researcher runs on `local`, the model inference serves to the lab
(`docs/inference/REFERENCE.md`), with Codex's middle tier behind it. Every
agent's session titles and post-turn memory review run on `local` too
(`sideTasks` in `agents.nix`), and context compression stays on Codex, since
a poor summary loses an agent's context for good.

Hermes reaches inference as the provider `lab-gpu`, not `local` or
`llamacpp`, which Hermes already uses for other things. The key is
`inference/agents-key`, which reaches each agent's `.env` as
`LAB_INFERENCE_KEY`; config.yaml has only the variable's name. Its context is
set to a slot's 64K, since llama-server reports the model's own, much larger
one.

When inference is down or busy, Hermes retries and then falls back: the
researcher to Codex, and side tasks to the agent's main model: Codex for most,
which quietly uses the plan's limits, and Claude for the reviewer, which
spends from the Anthropic key. inference's nginx
gives the `agents` key two requests at a time and answers a third with a 429,
which Hermes retries.

llama-server only reads a thinking switch from `chat_template_kwargs`, and
Hermes doesn't send one, so the researcher runs with the model's default, no
thinking. That's how it passed the model test.

Claude runs on an Anthropic API key, `anthropic/api-key`, from the Console
organization's Default workspace, which spends the account's monthly credits.
The Default workspace can't have a limit of its own, so the only caps are the
organization's spend limit and the credit balance, shared with everything
else on the account. Paperclip records every `hermes_gateway` run as
unpriced, whatever the model, so it doesn't cap Claude either. A dedicated
workspace with its own monthly limit would cap the agents alone; it spends
the same credits. The key reaches only the agents whose model, fallbacks or side
tasks name Claude, as `ANTHROPIC_API_KEY`, so the researcher doesn't have it,
and only the models in `roles.hermesAgents.anthropic.models` are allowed.
Hermes would also take a Claude login or OAuth token, ahead of the key, and
Anthropic's terms don't allow those in a third-party harness. So none can be
set in Nix, and each agent refuses to start if one turns up in its
`auth.json` or the key in SOPS is an OAuth token. What Claude sees is what
the agent sees: its SOUL.md, memory, Paperclip issues, and for the engineer,
reviewer and infra, code and terminal output from workbench.

Hermes merges these settings into the config.yaml it keeps on disk and keeps
keys that are no longer set. So the role always writes the side tasks it
manages (titles, memory review, compression), with `auto` for one that isn't
set, which hands it back to the main model. Taking one out of Nix is enough
to undo it.

### Decisions: Jev

Every agent has Jev, TypeSafe's decision model, as an MCP tool, `decide`
(`mcp__jev__decide`, found through Hermes' tool search like the Paperclip
tools). It takes a piece of text and up to 16 typed questions (`noul` for
yes or no, `choice`, `score`) and returns calibrated probabilities. It's
advisory. Each SOUL.md says when to use it:
- the coordinator checks whether a new issue needs the `change` or
  `sensitive` label, and Jev can only add a label;
- the engineer checks a step that deletes, rewrites history or touches CI,
  and a high score is never an approval;
- infra checks a change that removes a host, a service or a firewall rule
  against what the issue asked;
- the reviewer rarely needs it, and never sends it code;
- the researcher scores or classifies findings.

The server is `modules/roles/hermes-agents/jev-mcp/server.py`, the standard
library and the MCP SDK. Hermes starts it with only its own environment:
`JEV_API_KEY` from `jev/api-key`, the endpoint and a pinned model,
`jev-1.14.0`. Before a call it checks the questions against Jev's shapes,
caps the text at 60,000 characters, and refuses anything that looks like a
private key, an API token or a password. Its call log, `logs/jev.log` under
each agent's `.hermes`, has each call's id, time, size and outcome, never
the text, the questions or the answers. A session gets 25 calls before
Hermes wants an approval nobody gives. Calls cost $0.042 per million input
tokens, and output is free.

TypeSafe doesn't train on what it's sent, but keeps it "as long as necessary"
with no fixed period, and zero retention is for enterprise customers only.
That's why the SOUL files limit what goes to Jev to Paperclip issues and
public sources. The endpoint is any server that speaks the same System One
API (`roles.hermesAgents.jev.baseUrl`), so a local decision model can replace
it later for private text.

### Reviews

Every issue the coordinator gives the engineer or infra carries a review
stage for the reviewer, as the issue's execution policy (Paperclip's own
mechanism for cross-agent review). When the engineer or infra sets the issue
`done`, Paperclip moves it to `in_review` and hands it to the reviewer. The
reviewer reads the pull request (`gh pr diff`), checks it out with
`agent-review <owner/repo> <n>` on workbench to run its tests or
`scripts/flake-check.sh`, and decides in one update: `done` with a comment
starting "Approved:", or `in_progress` with numbered findings, which hands
the issue back. Two rounds of changes is the limit the coordinator sets;
after that the reviewer asks the board instead.

The reviewer also posts its findings on the pull request as a comment review
citing the issue. Every agent pushes as the same machine account, and GitHub
doesn't let a pull request's author approve or request changes on it, so the
comment is the record and Paperclip holds the verdict. Merging stays yours.

## How agents and tasks are meant to be set up

There's one company for the lab. Its CEO is the coordinator agent, and the
other agents report to it. Work outside the lab, such as anything for CGLT,
gets its own Paperclip instance on its own hosts rather than a second company
here, because companies on one instance share the admin and the master key.

Every agent action falls into one of four levels:

| Level | What it covers | Who |
|---|---|---|
| Observe | Reading state: dashboards, metrics, logs, read-only APIs | any agent, with read-only credentials |
| Prepare | Plans, research, code on agent branches, pull requests, Paperclip issues and comments | agents, on the execution host as their own user |
| Change | Anything that changes a running system or merges into a default branch | you. An agent asks with a board approval that names the exact PR or command. |
| Sensitive | Secrets, security settings, deleting data | you. Agent hosts don't have the credentials. |

Issues that would need Change or Sensitive work carry the label `change` or
`sensitive`. The label marks them and nothing more: Paperclip 2026.1023.0
keeps execution policies (review and approval stages) on each issue, with no
rule that adds one by label, project or company. What keeps Change and
Sensitive work with you is that agent hosts don't have the credentials for
it. Approvals happen in Paperclip's UI, which only the board can use. The
company requires the board's approval for new agents, so a hire the
coordinator asks for waits in the Inbox.

`scripts/agents/paperclip-apply.py` keeps that setup in line with
`scripts/agents/paperclip-spec.json`, a dry run unless given `--apply`:

```sh
scripts/agents/paperclip-apply.py
scripts/agents/paperclip-apply.py --apply
```

It sets the company's approval for new agents, creates missing labels, and
for each agent sets the role, reporting line, the adapter settings the spec
lists, timed heartbeats (off) and whether it may create agents. Keys the spec
leaves out stay as they are in Paperclip. A Hermes agent that's missing is
hired with its API key from the company secret the spec names as
`apiKeySecret`, and approved. The concierge joins through an invite, and
its adapter settings hold its gateway token, so it's never created and its
adapter settings are only reported. The script never deletes anything and
never sees a secret's value; things that exist only in Paperclip are listed
and left alone. Paperclip can't change a label, so a colour that differs is
only reported.

It signs in as the board through Paperclip's CLI sign-in: it prints a link
to approve in a browser that's signed in, gets a board key that's good for
30 days, and revokes it before exiting. With `PAPERCLIP_BOARD_KEY` set it
uses that key instead and leaves it alone. The `paperclip-spec` flake check
fails when the Hermes agents in the spec don't match `agents.nix` or their
ports differ.

## End-to-end smoke test

`scripts/agents/smoke-e2e.py`, run from the Mac, checks the whole path from
an issue to work on GitHub. It signs in as the board the same way as
`paperclip-apply.py` and runs these stages, all of them unless `--only`
names some:

| Stage | Passes when |
|---|---|
| `rulesets` | agent-scratch has both rulesets from `scripts/workbench/github-rulesets/`, active |
| `refused` | a push to agent-scratch's default branch, as `agent-engineer` on workbench with the machine account's token, is refused by the ruleset. It isn't tried while the branch ruleset is missing, because it would land. |
| `watch` | an issue labelled `change` raises a `MarkedChange` alert in Alerta on the next agent-watch pass, and cancelling the issue clears it. The phone gets both. |
| `ping` | the researcher comments the word it was asked for and closes the issue |
| `local` | the same, through the lab's local model: the researcher's main model is `lab-gpu`, Hermes logs no fallback while it works, and inference's nginx logs at least one successful request from the `agents` key |
| `decide` | the researcher asks Jev one fixed question and comments the call id it got back, which is in the Jev server's call log as a successful call |
| `change` | the engineer pushes an `agent/engineer/*` branch to agent-scratch with exactly the file it was asked for, opens a pull request as the machine account, and comments its URL. The pull request is then closed and its branch deleted, unless `--keep-pr`. |
| `review` | the same, on an issue with a review stage for the reviewer: Paperclip hands it over when the engineer sets it done, the reviewer approves it so the stage completes, and its findings are on the pull request as a comment review citing the issue |
| `infra` | infra adds one file to nixconfig on an `agent/infra/*` branch, runs `scripts/flake-check.sh eval` on workbench, and opens a pull request whose body reports the check passed |
| `gate` | asked to run `rm -rf ~/smoke-<nonce>` on workbench, the engineer is refused by Hermes' deny list, the refusal is in its log, and the canary file in that directory survives |

Most stages wait on real model runs, so a full run takes 20 to 45 minutes;
`--timeout-minutes` (20) bounds each. The pull requests from `change`,
`review` and `infra` are closed and their branches deleted afterwards, unless
`--keep-pr`. The issues stay in Paperclip,
titled `Smoke test <nonce>: ...`. It needs `gh` signed in as Justin and
`ssh agents`, `ssh workbench` and `ssh inference` with sudo. The Alerta key never leaves the
agents VM: the alert lookups run there.

A `gate` that fails with the canary intact and nothing in the log means the
model declined on its own, so the deny list wasn't exercised.

## Monitoring

Beszel's agent reports the host. Kuma watches it over the tunnel:

| Monitor | Check | Down means |
|---|---|---|
| `SVC / paperclip` | HTTP `https://paperclip.servicestack.xyz/api/health`, expect 200 and keyword `"ok"` | Paperclip, nginx, the database or the VM is down (or the tunnel) |
| `JOB / agents backup` | push, 26 h heartbeat (`kuma/backup-push-url`) | the nightly backup failed or didn't run |
| `JOB / agent-watch` | push, 15 min heartbeat (`agent-watch/kuma-push-url`) | agent-watch stopped, or can't read Paperclip or reach Alerta |

`/api/health` answers 200 with `"status":"starting"` while migrations run and
503 when the database is unreachable, so the keyword matters.

Paperclip has no Prometheus endpoint. Its own view of agent runs, costs and
the activity log is in its UI.

What happens inside Paperclip reaches the phone through agent-watch
(`agent-watch.nix`). Every five minutes it reads Paperclip and keeps these
alerts in Alerta on lab118-services, environment `Homelab`, origin
`agent-watch`:

| Event | Resource | When | Severity |
|---|---|---|---|
| `RunFailed` | `paperclip/<agent>` | the agent is in error, or its last finished run failed or timed out | minor |
| `IssueStuck` | `paperclip/LAB-<n>` | in progress for an hour with no run and no activity | warning |
| `ApprovalWaiting` | `paperclip/approval-<id>` | an approval waits on the board | warning |
| `MarkedChange`, `MarkedSensitive` | `paperclip/LAB-<n>` | an open issue carries that label | warning |
| `BudgetWarning` | `paperclip/budget-<id>` | a budget is past its warning level, or stopped (major) | warning |

An alert is cleared, which sends a resolved notification, on the first pass
where it no longer holds. agent-watch finds its open alerts by asking Alerta,
so it keeps no state, and its texts don't change while nothing does, so a
repeat doesn't notify again. Acknowledging an alert in Alerta keeps it quiet;
closing it there only lasts until the next pass. It reports every good pass
to Kuma, and a pass that can't read Paperclip or reach Alerta fails the unit
instead.

It reads with its own key on the researcher, the agent with the least
authority on this host, so it sees what any agent sees: not private issues
assigned to someone else. Reading the issue list can make Paperclip cancel a
stale recovery action, which the activity log then credits to the
researcher. Model fallbacks only show in Hermes' own logs, so it doesn't
report them. It runs as a throwaway user with its secrets as systemd
credentials, and posts to `http://10.118.0.1:5000` over the lab tunnel.
`agents.watch.enable` in `configuration.nix` turns it off.

## Secrets

`secrets/hosts/agents.yaml` is encrypted to the host's own age key and the
operator key, nothing else. On macOS, edit it with
`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/agents.yaml`.

| Key | What |
|---|---|
| `paperclip/master-key` | `openssl rand -hex 32`. Never change it; keep a copy in 1Password. |
| `paperclip/better-auth-secret` | `openssl rand -hex 32`. Signs sessions; changing it signs everyone out. |
| `paperclip/agent-jwt-secret` | `openssl rand -hex 32`. Signs agent run tokens. |
| `paperclip/database-password` | `openssl rand -hex 32`. Hex only, since it goes into a URL as-is. |
| `beszel/agent-token` | the hub's universal token |
| `porkbun/api-key`, `porkbun/secret-api-key` | for DNS-01 |
| `kuma/backup-push-url` | push monitor for backups |
| `agent-watch/paperclip-key` | a second Paperclip key on the researcher, named `agent-watch` |
| `agent-watch/alerta-key` | an Alerta API key with `read:alerts` and `write:alerts` |
| `agent-watch/kuma-push-url` | the `JOB / agent-watch` push monitor's URL |
| `root/console-password-hash` | `mkpasswd -m yescrypt` |
| `hermes/<name>/api-server-key` | `openssl rand -hex 32`, one per agent. Also goes into Paperclip as that agent's adapter `apiKey`. |
| `hermes/<name>/paperclip-key` | the agent's Paperclip key, only for agents listed in `withPaperclipKey` |
| `inference/agents-key` | the agents' key for inference, the same value as `inference/keys/agents` in `secrets/hosts/inference.yaml` |
| `anthropic/api-key` | an Anthropic API key from the Console's Default workspace, capped only by the organization's limit and credits. Never an OAuth token. |
| `jev/api-key` | a TypeSafe API key, from console.typesafe.ai |
| `hermes/<name>/ssh-key` | for the engineer, reviewer and infra: `ssh-keygen -t ed25519 -N ''`, the private half; the public half goes in `workbench.agents.<name>.publicKey` in `hosts/workbench/agents.nix`. Needed once `workbenchHostKey` is set. |

The host key is installed by `nix run .#install` from `HOST_AGE_KEY_FILE`
(`hostAgeKey = true` in `infra/terranix/default.nix`), the same way as on
dashboard. Until `secrets/hosts/agents.yaml` exists, the real host fails to
build with a message saying so, and so does `nix flake check`.

## Backups

`roles.sqliteBackup` runs at 03:15 (plus up to 10 minutes):
- It dumps the `paperclip` database with `pg_dump --format=custom` as
  `postgres` and checks the dump reads back with `pg_restore --list`.
- It copies `/var/lib/paperclip` and the master key's fingerprint.
- It encrypts the archive to the host and operator keys and writes it to
  `/mnt/agents-backups` (NFS, mounted on demand, `soft`).
- It reads the archive back, keeps 30 days (never fewer than 7 archives),
  and reports to `kuma/backup-push-url`.

The export is `10.0.0.20:/mnt/Main/backups/agent-backups` on TrueNAS
(`agents.backup.nfsDevice`). Like the dashboard's, it should only accept the
VM's address and map root to root.

```sh
sudo systemctl start sqlite-backup     # a backup now
sudo sqlite-backup list                # archives, newest first
sudo sqlite-backup restore /mnt/agents-backups/agents-<time>.tar.zst.age
```

A restore checks the dump and the key fingerprint before touching anything.
It then stops Paperclip, and keeps the current database as
`/var/lib/sqlite-backup/pre-restore/paperclip.pre-restore-<time>.pgdump` and
the data directory as `/var/lib/paperclip.pre-restore-<time>`. It restores
the database in one transaction and starts Paperclip again. PostgreSQL keeps
running throughout. If `pg_restore` fails, the database is unchanged and
Paperclip stays stopped.

`--clean` drops and recreates what's in the dump. Tables a newer migration
added after the dump was taken stay behind, so restore into the version the
backup came from (the archive's `metadata.json` records the image).

## Operations

### The application misbehaves

```sh
sudo systemctl restart podman-paperclip
sudo journalctl -u podman-paperclip -n 100
sudo podman inspect --format '{{.State.Status}} {{.RestartCount}}' paperclip
```

If Paperclip won't start and the journal says the master key doesn't match,
the SOPS value changed. Put the original key back.

### Upgrading

Read the release notes, run `sudo systemctl start sqlite-backup`, change the
image (tag and digest) in `hosts/agents/configuration.nix`, then switch.
Migrations run on start and only go forward, so rolling back means the
previous image and restoring the pre-upgrade backup.

PostgreSQL is pinned to 17 in the role, so a `stateVersion` change never
moves it. A major upgrade is a dump and a restore into the new version.

### Rebuilding the VM

As for dashboard: `nix run .#provision -- agents` with `HOST_AGE_KEY_FILE`
and `SSH_PRIVATE_KEY_PATH` set, then restore the newest backup. With the same
host key and the same master key in SOPS, the stored secrets stay readable.

## Known limits

- The OCI image moves weekly and isn't built by Nix. There's no nixpkgs
  package or upstream flake; native packaging would mean a pnpm workspace with
  patched dependencies and prebuilt binaries.
- Login is email and password. Paperclip has no OIDC, so Pangolin's SSO and
  Paperclip's login are separate.
- No Prometheus metrics. Run status, costs and the activity log are in the UI
  and the API.
- The VM and its backups share one NAS, as on dashboard.
- The Hermes agents' state (sessions, memories, logins) isn't in the backup
  yet. The backup refuses a database that doesn't exist, and an agent has no
  `state.db` until its first run.
- Nothing caches Hermes' build, so the first switch after a Hermes update
  builds it on this VM.
- Five agents at their 2 GB `MemoryMax` plus Paperclip's 4 GB add up to more
  than the VM's 12 GB. Those are caps, and an idle agent uses far less, but
  several long runs at once could press on memory.
- The reviewer can only comment on GitHub: every agent pushes as one machine
  account, and GitHub doesn't let a pull request's author approve it.
  Paperclip's review stage is the gate.
- The egress filter knows the LAN by its private IPv4 ranges and IPv6's
  local ones. If the LAN ever gets a routed IPv6 prefix, its hosts become
  reachable at their global addresses until the prefix is added to the
  filter.

## Gotchas

- Don't run Paperclip's onboarding in the container: it writes a config file
  that can override the environment the role sets.
- `PAPERCLIP_AUTH_DISABLE_SIGN_UP` also blocks accepting an invite as a new
  user. Turn sign-up on briefly to add someone, or don't add anyone.
- The image ships Claude Code, Codex and other CLIs for the local adapters.
  Logging any of them in inside the container would give every local-adapter
  agent that account.
- The web onboarding asks for a first agent and offers only those local
  adapters, with a sign-in step that does exactly that. Agents here are
  `hermes_gateway` hires instead. While the company has no agents, the
  dashboard opens the wizard on every page load and it has no close button, so
  load `/<prefix>/agents/new?name=Coordinator&adapterType=hermes_gateway`
  directly, where `<prefix>` is the company's prefix from any board URL.
- The New Agent page names every key typed into it `API_SERVER_KEY · agent
  setup`, and Paperclip refuses a second secret with a name already in use, so
  only the first hire can take a typed key. For the others, add the key on the
  Secrets page under a name of its own and pick it as the organization secret,
  or type it on the agent's Configuration page after the hire, which stores it
  under a unique name. Don't give a secret the key `API_SERVER_KEY` itself: the
  page would preselect it for every later hire.
- The connection test only calls Hermes' `/health`, which takes no key, so it
  passes with another agent's key. A wrong key shows up as a 401 on the
  agent's first run.
- Paperclip's "disable adapter" setting only hides an adapter from menus; it
  still works.

## Related

- `docs/workbench/REFERENCE.md`: where the engineer's terminal and file
  tools act.
- `docs/openclaw/REFERENCE.md`: the concierge, which files work in Paperclip
  for the coordinator.
- `docs/dashboard/REFERENCE.md`: the split-horizon pattern, Beszel, HA.
- `docs/lab118-services/REFERENCE.md`: Kuma, the alert pipeline and the tunnel.
- `readme.md`: the provisioning commands.
