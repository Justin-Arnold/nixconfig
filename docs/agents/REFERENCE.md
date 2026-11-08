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
| Agents | Hermes v0.22.5: `coordinator`, `engineer`, `researcher`, `reviewer`, `infra`, `monitor`, one process each, API servers on `127.0.0.1:8642` to `8647` |
| Models | Codex for the coordinator, engineer and infra, with Claude Opus 5.5 as their last fallback; Claude Opus 5.5 for the reviewer, with Sonnet 5.5 and Codex behind it; the lab's GPU (`local` on inference) for the researcher and the monitor, with Codex behind them, and for every agent's session titles and memory review |
| Tools from outside | Jev, TypeSafe's decision model, as every agent's `decide` tool; read-only Proxmox, Beszel, Kuma and Alerta for the coordinator, infra, the researcher and the monitor; read-only GitHub for the coordinator and the researcher |
| Login | `ssh agents` as `justin`, key only (the Mac Mini key). Root has no SSH. |
| Console | Proxmox console, root password from SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/agents.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Routines | A lab health review every morning and alert triage, for the monitor; a flake.lock pull request every Monday, for infra; a pull request review when you ask, for the reviewer |
| Backups | Nightly at 03:15, NFS share on the NAS, age-encrypted, Kuma push monitor |

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/agents/configuration.nix` | The host: users, SOPS, Podman, Paperclip, the Beszel agent, and the exposure assertions. |
| `hosts/agents/endpoints.nix` | ACME (Porkbun DNS-01), the nginx vhost and its allow-lists. |
| `hosts/agents/nginx/paperclip-guard.conf` | The locations that keep Paperclip's MCP endpoint and public routine webhooks unreachable. |
| `hosts/agents/backup.nix` | The NFS mount and what gets backed up. |
| `hosts/agents/agent-watch.nix`, `hosts/agents/agent-watch/` | The timer that turns Paperclip's state into Alerta alerts, and its test against fakes. |
| `hosts/agents/agent-costs.nix`, `hosts/agents/agent-costs/` | Each agent's Claude and Jev spend, reported to Paperclip and summed for agent-watch's credit alerts, and its test. |
| `hosts/agents/board-bridge.nix`, `hosts/agents/board-bridge/` | The service that sends what waits on the board to Telegram and Discord and answers it from a tap, and its test against fakes. |
| `hosts/agents/paperclip-events.nix`, `hosts/agents/paperclip-events/` | The relay that turns Paperclip's live events into nudges for agent-watch, board-bridge and agent-costs, and its test against a fake Paperclip. |
| `hosts/agents/packages-check.nix` | The `agents-packages` check: builds the MCP servers, the services' Python and workbench's scripts as they're deployed. |
| `hosts/agents/eval-test.nix` | Example values for the flake checks, not used by the real host. |
| `infra/terranix/hosts/agents.nix` | The VM, its storage, CPU type and HA resource. |
| `hosts/agents/agents.nix` | The Hermes agents, their models, which ones have a Paperclip key, and what they may reach in the LAN. |
| `hosts/agents/souls/` | Each agent's SOUL.md: its job and its limits, each ending with `asking-justin.md`, how to ask you a question. |
| `modules/roles/paperclip.nix` | Paperclip under Podman, its database, the key guard and the health watch. |
| `modules/roles/hermes-agents.nix` | One Hermes unit per agent, built from upstream's own module helpers, and the assertions that keep them shell-free. |
| `modules/roles/hermes-agents/paperclip-mcp/` | Paperclip's MCP server, pinned by a lockfile to the Paperclip release. |
| `modules/roles/hermes-agents/jev-mcp/` | The Jev MCP server (`server.py`), its package and its test against a fake TypeSafe API. |
| `modules/roles/hermes-agents/lab-mcp/` | The lab MCP server: read-only Proxmox, Beszel, Kuma and Alerta, and its test against fakes of all four. |
| `modules/roles/hermes-agents/github-mcp/` | GitHub's MCP server at a pinned release, behind a wrapper that keeps it read-only. |
| `modules/roles/agent-egress.nix` | The outbound filter that keeps the agents off the LAN. |
| `modules/roles/sqlite-backup.nix` | Backups, including the PostgreSQL dumps. |
| `scripts/agents/post-install-check.sh` | Read-only health report. |
| `scripts/agents/paperclip-apply.py`, `paperclip-spec.json` | Paperclip's company setting, labels, agents and routines as a spec, applied through its API. |
| `scripts/agents/routines/` | What each routine asks its agent to do. |
| `scripts/agents/paperclip-cancel.py` | Cancels Paperclip issues by identifier, such as a smoke test's leftovers. |
| `scripts/agents/paperclip-board-key.py` | Makes board-bridge's board key and writes it into SOPS without printing it. |
| `scripts/agents/paperclip-agent-key.py` | Makes a service's key on an agent, such as paperclip-events' on the researcher, and writes it into SOPS without printing it. |
| `scripts/agents/tests/` | Fake Paperclips that `paperclip-apply.py`, `paperclip-cancel.py` and the two key scripts are tested against in the `provisioning` check. |
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
| `/api/routine-triggers/public/*` | nobody | 404 |
| everything else | LAN (Pangolin included), VPN | Paperclip, `127.0.0.1:3100` |
| unknown names, bare IP | nobody | no certificate, no content |

`/mcp/paperclip` is Paperclip's experimental MCP endpoint for outside
assistants acting as a signed-in person. It's off in Paperclip, and nginx
keeps it unreachable regardless. Routine webhooks are where outside systems
fire routines. A trigger can be created with no authentication, so they stay
closed on this name.

One other name reaches Paperclip, made for one sender: n8n on the automation
VM, which starts infra's or the engineer's Fix CI routine when CI goes red
(`docs/automation/REFERENCE.md`). It has its own certificate and doesn't
include the guard, and it answers nothing but a trigger's fire URL.

| `paperclip-triggers.servicestack.xyz` | Who may use it | Goes to |
|---|---|---|
| `/api/routine-triggers/public/<24 hex digits>/fire` | the automation VM (`10.0.0.155`), POST only | Paperclip, at that trigger's fire path, rebuilt from the id alone |
| everything else | nobody | 404 |

Every webhook trigger is signed with bearer, so firing one also takes the
secret n8n holds; `paperclip-apply.py` refuses any other signing mode.
Paperclip only accepts hostnames it knows, so this one is in
`roles.paperclip.allowedHostnames`. The assertions in `endpoints.nix` keep
both server blocks this way, and a server block that reaches Paperclip any
other way, a path or variable after the upstream included, has to include
the guard.

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
- An AdGuard rewrite for `paperclip.servicestack.xyz` to the VM's address,
  and one for `paperclip-triggers.servicestack.xyz`, which n8n uses.
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

There are no Paperclip budgets, on purpose. Paperclip records every
`hermes_gateway` run as unpriced, provider `hermes_gateway`, whatever the
model, and a budget policy blocks on unpriced usage unless its
`unpricedUsagePolicy` is `allow`; with the default, a budget pauses its agent
after the first run. A paused agent also stops its free work on Codex and the
local model. So the limit is the money itself: the Claude credits loaded each
month and Jev's credits, with alerts as they run low or out ("Spend" below).
A budget added later needs `unpricedUsagePolicy: allow`, and only counts what
agent-costs reports.

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
reach inference on 443, the agents with a terminal there reach ssh on
workbench, and the agents with the lab tools reach the Proxmox nodes on 8006,
the dashboard VM on 443 and lab118 on 3002 and 5000 over the tunnel. Hermes'
own `allow_private_urls: false` refuses
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
adapter's `timeoutSec`, and marks the issue blocked. The spec gives every
agent its own: 600 seconds, Paperclip's default, for the coordinator, the
engineer and the researcher; 900 for the monitor; 2400 for the reviewer and
infra, because nixconfig's checks alone take longer than ten minutes on
workbench. A command the agent started in the background keeps running there
after its run is stopped. The monitor also runs one thing at a time and at
most 30 times a day (`maxConcurrentRuns` and `maxDailyRuns` in its
heartbeat), since its work starts on its own.

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
researcher and the monitor run on `local`, the model inference serves to
the lab (`docs/inference/REFERENCE.md`), with Codex's middle tier behind it. Every
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
researcher and the monitor to Codex, and side tasks to the agent's main model: Codex for most,
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
the same credits. When the credits run out, Hermes takes Anthropic's refusal
as a billing failure and moves to the next fallback at once: the reviewer to
Sonnet, which uses the same credits, then Codex; the others keep running on
Codex. agent-watch alerts both before and when that happens ("Spend"). The key reaches only the agents whose model, fallbacks or side
tasks name Claude, as `ANTHROPIC_API_KEY`, so the researcher and the monitor don't have it,
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

### Lab state: Observe tools

The coordinator, infra, the researcher and the monitor can read the lab's state through
the lab MCP server (`modules/roles/hermes-agents/lab-mcp/server.py`, the
standard library and the MCP SDK), and the coordinator and the researcher can
read GitHub. Nothing here can change anything: each credential can only read,
and the lab server only sends GETs to a fixed list of paths.

| Source | Tools | Credential | What it doesn't show |
|---|---|---|---|
| Proxmox | `proxmox_cluster`, `proxmox_resources`, `proxmox_node`, `proxmox_guest`, `proxmox_failed_tasks` | API token `agents@pve!observe` with a role of `Sys.Audit`, `VM.Audit`, `Datastore.Audit` and `Pool.Audit` on `/`, over HTTPS against the cluster's own CA, two nodes tried in turn | VM configs (with their descriptions and keys), task logs, firewall, users and ACLs: the server never asks |
| Beszel | `beszel_systems`, `beszel_system` | a user with Beszel's `readonly` role | the agent fingerprints, which hold each system's agent token, and anyone's settings: the server refuses those collections. Its alerts are its own, not Justin's. |
| Kuma | `kuma_monitors` | none: the `agents` status page over the lab tunnel | error messages (Kuma blanks them on status pages), monitors not on that page, and URLs, since the page has no clickable links |
| Alerta | `alerta_alerts`, `alerta_alert` | a key scoped to `read:alerts` only, separate from agent-watch's | alert attributes and raw data, and who changed an alert |
| GitHub | 19 read tools (`get_file_contents`, `list_pull_requests`, `issue_read`, `search_code`, ...) | a fine-grained token from Justin's account, all repositories, read-only | nothing it can write: `--read-only` registers only read tools, and the wrapper ignores any arguments |

GitHub's server is `github-mcp-server` 1.14.0, newer than nixpkgs' 1.3.0
because 1.10.0 hardened it, built with nixpkgs' Go 1.26. It runs with
`--read-only --lockdown-mode --toolsets=repos,issues,pull_requests`, from an
empty directory, since it reads replacement tool descriptions from a file in
its working directory. Lockdown hides issue and pull request text from people
without push access on public repos, but it's best effort: the SOUL files say
such text is information, not instructions. The token reads every repo
Justin owns, so a planted instruction could make an agent read a private
one; it can't make it write anywhere.

Kuma and Alerta are plain HTTP over the WireGuard tunnel to lab118, the same
way agent-watch reaches Alerta. The egress filter lets the agents with the
lab tools reach only 3002 (Kuma's status page) and 5000 (Alerta) there, never
Node-RED on 1880, which holds a write key for Alerta, or ntfy on 8080. The
lab server writes `logs/lab.log` under each agent's `.hermes` with each
call's id, tool and outcome, never what came back.

A source is on once it's in `observeReady` in `agents.nix` with its
credential in SOPS; Proxmox also needs `proxmoxNodes` and `proxmoxCa`. GitHub
is on with `withGithubToken`. The agents' Proxmox token is its own, so it can
be revoked without touching Homarr's or Terraform's.

### Spend

Only Claude and Jev cost money: Codex is part of the ChatGPT plan, and the
lab's model is free. Hermes keeps what every call used in each agent's
`state.db` (`session_model_usage`, by session, model and task, side tasks and
fallbacks included), and the Jev server's `logs/jev.log` has each call's
input tokens. agent-costs (`hosts/agents/agent-costs.nix`) carries that to
Paperclip.

After each of an agent's runs (see Live events), and hourly anyway, a unit
`agent-costs-<name>` runs as that
agent, reads only its own state and logs, and posts what's new as cost
events with the agent's own Paperclip key, which can only report that
agent's costs. Claude is priced from its tokens with the rate card in
`roles.hermesAgents.anthropic.prices` (Opus 5.5 $4 and $20 per million in
and out, Sonnet 5.5 $2 and $10, Haiku 5.5 $0.10 and $0.50, cache writes at
1.25 times input, cache reads at 0.1 times), since Hermes' own table doesn't
know every model; a Claude model not on the card falls back to Hermes'
estimate. Jev is $0.042 per million input tokens. The events are marked
`estimated`, carry the token counts in their pricing note rather than as
tokens, so Paperclip doesn't count tokens twice next to the run's own event,
and have keys that make a repeat harmless. Anthropic's console has what was
actually billed.

Each run also writes `/var/lib/agent-costs/<name>/month.json`: this month's
Claude and Jev cents, and when each last worked and last refused for
credits (Hermes' warning `… via anthropic refused for billing/credits`, and
`reason=billing` in `jev.log`). agent-watch reads those for the credit
alerts below. `agents.costs` in `agent-costs.nix` sets the month's Claude
credit (`claudeMonthlyCredits`, $100) and when to warn (`claudeWarnPercent`,
80%).

```sh
ssh agents 'sudo systemctl start agent-costs-reviewer; cat /var/lib/agent-costs/*/month.json'
```

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

### Asking you

When an agent needs a decision from you, it asks in Paperclip, not in a
comment, since a comment reaches nobody. Every agent's soul ends with the
same section on this (`souls/asking-justin.md`):

- A choice is a question card (`paperclipAskUserQuestions`) with two to four
  options, the agent's recommendation first, each with its trade-off.
- A yes or no is a confirmation (`paperclipRequestConfirmation`), always set
  to wake the agent when you answer. Paperclip's default for confirmations
  is not to.
- Something only you can do is a comment saying exactly what, with a
  confirmation for you to say it's done.
- A board approval is made with its issue in `issueIds`, which links it.
- Then the agent sets its issue `blocked` and ends its run. Paperclip lets
  an issue wait on a pending question or approval, and refuses an agent
  that names the board as the unblock owner, so agents give the status
  alone.

It reaches you three ways, and any of them answers it:

- agent-watch raises `WaitingOnYou` for an open issue with an unanswered
  question, and ntfy shows it with a link to the
  issue, which opens over the LAN, the VPN or Pangolin. `ApprovalWaiting`
  links to the approval the same way.
- board-bridge sends it as a Telegram DM and a Discord DM with buttons (see
  below).

Your answer wakes the agent on the same issue, it carries on from where it
stopped, and the alert clears on the next pass.

The monitor only reads, so it never asks: when its review or triage finds
something that needs you, it leaves the issue blocked with what to do, and
you close it when it's done.

### Telegram and Discord

board-bridge (`board-bridge.nix`) is a small service on this host with no
model in it. Within seconds of a change in Paperclip (see Live events),
and every 5 minutes anyway, it reads, with a board key, the pending
questions and confirmations on open issues and the pending approvals, and
sends each new one to every channel that's on as a DM: the issue, the agent
that asked, the question and its options with their trade-offs, buttons,
and a link to it in Paperclip.

- A question with one question gets a button per option. Multiple choice
  gets toggles and Submit, and a free-text option or "Other" asks for text.
- A confirmation gets Accept, Reject, and Reject with a reason. A checkbox
  confirmation gets toggles, starting from its defaults.
- An approval gets Approve, Reject, and Reject with a note, in one tap.
- Anything else, like a form with several questions or a tool action to
  confirm, gets the link alone.

Text comes as a reply to the bot's prompt in Telegram, and as a form in
Discord. A press answers in Paperclip as you, through the same calls as
the board's own buttons, so the agent wakes the same way. Approving an
approval wakes the agent that asked for it; Paperclip doesn't wake it when
you reject one.

Only presses and replies from the user IDs in
`agents.boardBridge.<channel>.userId`, in a DM, count. Everything else is
logged and ignored, and a message that isn't a reply to the bot's prompt
does nothing. When an item is answered in a chat, every copy changes at
once to say where and what, and loses its buttons; answered in Paperclip,
within seconds. Question text comes
from agents, so it's sent as plain text and trimmed.

The board key can do anything the board can, so the bridge's code calls
only the routes in its `ROUTES` list and refuses anything else: listing,
answering questions and confirmations, and deciding approvals. Its unit
reaches loopback and the internet, never the LAN, and an assertion holds
that. It polls Telegram and holds Discord's gateway open, so nothing comes
in. The Telegram bot can only DM you once you've started it, and the
Discord bot only while it shares a server with you.

`/var/lib/board-bridge/status.json` says when a pass last worked, what last
went wrong, where each waiting item went, and how many answers came from
Telegram, Discord and Paperclip, which is the comparison the three channels
are there for. agent-watch raises `BridgeStale` when it hasn't had a good
pass for 15 minutes. `agents.boardBridge.<channel>.enable = false` turns one
channel off, and `state.json` beside it keeps what was sent where, so a
restart sends nothing twice.

```bash
ssh agents 'sudo cat /var/lib/board-bridge/status.json; journalctl -u board-bridge -n 20 -o cat --no-pager'
```

`scripts/agents/paperclip-board-key.py` makes the key: a named board key
that doesn't expire, since a sign-in's own key lasts 30 days. It writes it
to SOPS on stdin and revokes its sign-in. An older board-bridge key keeps
working until `--revoke-old` revokes all but the newest.

### Live events

Paperclip keeps a live websocket for each company, which its own UI uses to
stay current, and paperclip-events (`paperclip-events.nix`) holds one open
on this host. It turns each event into a nudge for whichever service acts
on it, so they react within seconds instead of on their timers:

| Service | Nudged by | Its timer, now a sweep |
|---|---|---|
| agent-watch | questions, confirmations and approvals coming and going, issues made or changed, finished runs, an agent's status | every 5 minutes, which also covers what's about time passing, like a stuck issue |
| board-bridge | questions, confirmations and approvals coming and going, and Discord connecting | every 5 minutes, or 20 seconds after a pass that couldn't read Paperclip or reach a channel |
| `agent-costs-<name>` | each of that agent's finished runs | hourly |

An event only says that something changed (an action and an id, or a
run's status), never what it says, and each service reads what it needs
from Paperclip itself, as it always did. The relay leaves a file in
`/run/paperclip-events/<service>.d/`, and a path unit starts the service
while that folder isn't empty. The service empties it as it starts and
waits 10 seconds after it stops (`agents.events.cooldownSeconds`), so
changes during a pass make one more pass, and a busy run's dozens of
changes make a few. board-bridge runs all the time, so it's told with
`SIGHUP`. After every reconnect the relay nudges everything once, for
whatever it missed.

The websocket takes agent keys only, so the relay has its own key on the
researcher, named `paperclip-events`, which
`scripts/agents/paperclip-agent-key.py paperclip-events` makes and writes to
SOPS. It reaches Paperclip on loopback and nothing else.
`/var/lib/paperclip-events/status.json` says whether it's connected and how
many nudges each service got, and agent-watch raises `EventsStale` once it
has been disconnected for 5 minutes.

```bash
ssh agents 'sudo cat /var/lib/paperclip-events/status.json; journalctl -u paperclip-events -n 20 -o cat --no-pager'
```

### Routines

Some work starts on its own, as Paperclip routines: each makes an issue for
its agent from a template, on a schedule or when something runs it.
`paperclip-spec.json` lists them, `paperclip-apply.py` keeps Paperclip in
line with it, and what each asks its agent is in `scripts/agents/routines/`.

| Routine | Agent | Starts | What it does |
|---|---|---|---|
| Lab health review | monitor | every day at 07:00 New York time | Reads every lab source and says what's down, degraded or heading the wrong way, leading with whether anything needs you; if something does, the issue stays blocked on you |
| Triage lab alerts | monitor | n8n, when alerts open in Alerta | Reads each new alert and what it's about, and gives the likely cause and the next step; blocked on you the same way when one needs you |
| Fix CI on a pull request | infra | n8n, when `check.yml` finishes red on an `agent/ci/*` or `agent/infra/*` branch | Reads what failed, reproduces only that, fixes what it may and asks you about the rest, and pushes to the same branch |
| Fix CI on a pull request (engineer) | engineer | n8n, the same way for an `agent/engineer/*` branch | The same instructions, for the engineer's own branch |
| Review a pull request | reviewer | when you run it in Paperclip, with a repository and a number | Reviews that pull request the way it reviews a review stage, and comments on it |

The scheduled ones skip a tick while the last one's run is still going, and
after downtime fire one late run at most. Paperclip's cron reads the day of
the week as 0 to 6, Sunday first, and when a day of the month and a day of
the week are both set, both have to match. `{{date}}` in a title is the UTC
date. The review's repository is a choice between nixconfig and
agent-scratch, the two the machine account can reach, and its number is a
number, so nothing typed into a run reaches a prompt as free text. Fix CI
takes the same two, with nixconfig the only choice, and n8n sends nothing
else.

The weekly flake update has no model in it any more. A GitHub Actions
workflow, `update-flake-lock.yml`, opens the pull request every Monday and
starts its checks (`docs/workbench/REFERENCE.md`, CI). A green result tells
you it's ready to land, and only a red one wakes infra, through Fix CI.
Paperclip combines a Fix CI run with a live one only when the variables
match, so a second red on the same pull request joins the open issue and a
different pull request gets its own. After CI has gone red on three different commits of one pull request,
n8n wakes nobody for the fourth and raises CIStuck for you instead
(`docs/automation/REFERENCE.md`).

A routine paused in Paperclip stays paused: `paperclip-apply.py` reports it
and leaves it alone. It never deletes or archives a routine. A webhook
trigger it makes is signed with bearer, and Paperclip shows the secret only
then, so the script writes the trigger's URL (on the triggers name) and its
secret straight into `secrets/hosts/automation.yaml`, at the trigger's
`secretsTo`, without printing either. A trigger whose URL or secret isn't
there gets a new secret the same way, and n8n's credential for it then has
to be made again. Nothing a routine starts can change the lab: the monitor
only reads, infra stops at a pull request you land with `land-pr.sh`, and the
reviewer only comments. A routine can't carry a review stage, so the
flake.lock pull request has no reviewer but you.

n8n on the automation VM is what starts a triage (`docs/automation/REFERENCE.md`,
"Alerts from Alerta"). Alerta's plugin tells it when an alert opens, and it
waits 3 minutes so a burst becomes one issue. While the monitor is still on
an earlier triage, it waits for that to end. Then it runs the triage
routine's webhook with the ids of the alerts it hasn't handed over yet. Only
ids go to Paperclip; the monitor reads each alert itself. It skips the
agents' own alerts, n8n's and the end-to-end test script's, so nothing loops
back, as well as anything below `warning` and Kuma's test notification. Each
alert it hands over gets an `n8nTriagedAt` attribute in Alerta, so one that
reopens or changes severity is new again; an acknowledged one isn't open, so
it isn't triaged. The webhook can only start this routine, and n8n's key on
the researcher is fenced to one GET of the routine's open issues. The
monitor's `maxDailyRuns` of 30 caps how many triages a day can start.

agent-watch raises IntakeStale when an alert that n8n should have handed
over has been open 15 minutes without it, unless it's waiting behind a triage
open less than an hour. It reads Alerta and that routine's open issues
itself, with the same rules as n8n (`agents.watch.intake`, which an
assertion keeps the same as the workflow).

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

`scripts/agents/paperclip-cancel.py` cancels issues by identifier, signing in
the same way:

```sh
scripts/agents/paperclip-cancel.py LAB-29 LAB-33
```

It lists each issue's status and title, leaves the ones already done or
cancelled alone, and cancels the rest once you answer yes (`--yes` skips the
question). If an identifier isn't found it cancels nothing. A cancelled issue
can be reopened in Paperclip.

## End-to-end smoke test

`scripts/agents/smoke-e2e.py`, run from the Mac, checks the whole path from
an issue to work on GitHub. It signs in as the board the same way as
`paperclip-apply.py` and runs these stages, all of them unless `--only`
names some:

| Stage | Passes when |
|---|---|
| `rulesets` | agent-scratch has both rulesets from `scripts/workbench/github-rulesets/`, active, and the machine account's token has no `workflow` scope, so the agents can't change CI |
| `refused` | a push to agent-scratch's default branch, as `agent-engineer` on workbench with the machine account's token, is refused by the ruleset. It isn't tried while the branch ruleset is missing, because it would land. |
| `watch` | an issue labelled `change` raises a `MarkedChange` alert in Alerta on the next agent-watch pass, and cancelling the issue clears it. The phone gets both. |
| `ping` | the researcher comments the word it was asked for and closes the issue |
| `local` | the same, through the lab's local model: the researcher's main model is `lab-gpu`, Hermes logs no fallback while it works, and inference's nginx logs at least one successful request from the `agents` key |
| `decide` | the researcher asks Jev one fixed question and comments the call id it got back, which is in the Jev server's call log as a successful call |
| `observe` | the researcher reads each lab source it has once and comments the call ids, each a successful call of that source in the lab server's log; with GitHub on, it quotes nixconfig pull request #1's title, which matches GitHub's |
| `health` | the board runs the monitor's health review; the monitor comments and sets the issue done, and its lab log shows a successful call to every source it has during the run |
| `intake` | a minor test alert, `smoke/<nonce>`, goes into Alerta and nothing else is done: n8n has to start a triage naming it within 12 minutes and mark the alert's `n8nTriagedAt`, and the monitor's triage of it ends done with a comment naming `smoke/<nonce>`, which it can only learn by reading the alert, and an `alerta_alert` call in its log. The alert is cleared afterwards, and the phone gets both. |
| `ask` | the researcher asks the board a two-option question on an issue and leaves the issue blocked; agent-watch raises `WaitingOnYou` linking to the issue; the test answers as the board with the second option, and the researcher wakes, comments that option and closes the issue, after which the alert clears. The phone gets both. With board-bridge on, the question reaches every chat channel, and every copy ends up answered in Paperclip. With paperclip-events connected nothing is forced: the alert has to come within 20 s of the question, the DMs within 10 s, and the alert has to clear on its own. |
| `approve` | the same for an approval: the researcher asks for one, linked to its issue, and leaves the issue blocked; `ApprovalWaiting` links to it, and board-bridge sends it to every chat channel; the test approves it as the board, and the researcher wakes, comments the decision and closes the issue |
| `change` | the engineer pushes an `agent/engineer/*` branch to agent-scratch with exactly the file it was asked for, opens a pull request as the machine account, and comments its URL. The pull request is then closed and its branch deleted, unless `--keep-pr`. |
| `review` | the same, on an issue with a review stage for the reviewer: Paperclip hands it over when the engineer sets it done, the reviewer approves it so the stage completes, and its findings are on the pull request as a comment review citing the issue |
| `costs` | agent-costs reports the reviewer's Claude spend from the review stage: its `month.json` shows some this month, and Paperclip shows the same amount against the Reviewer |
| `infra` | infra adds one file to nixconfig on an `agent/infra/*` branch, runs `scripts/flake-check.sh eval` on workbench, and opens a pull request whose body reports the check passed |
| `gate` | asked to run `rm -rf ~/smoke-<nonce>` on workbench, the engineer is refused by Hermes' deny list, the refusal is in its log, and the canary file in that directory survives |
| `route` | a GitHub `ping`, signed with `github/webhook-secret` from `secrets/hosts/automation.yaml`, goes to `intake.lab118.xyz/github` and comes back with n8n's answer, through lab118-services, the tunnel and the automation VM. The same ping unsigned, or signed with another secret, gets 401, and a GET gets nothing. No model runs. |

Most stages wait on real model runs, so a full run takes 20 to 45 minutes;
`--timeout-minutes` (20) bounds each. The pull requests from `change`,
`review` and `infra` are closed and their branches deleted afterwards, unless
`--keep-pr`. The issues stay in Paperclip,
titled `Smoke test <nonce>: ...`. It needs `gh` signed in as Justin,
`ssh agents`, `ssh workbench` and `ssh inference` with sudo, and for `route`
the operator's age key, since it reads the webhook secret with sops. The Alerta key never leaves the
agents VM: the alert lookups and the test alert run there. The flake.lock and
pull request review routines aren't in it, since they make real pull
requests or spend Opus; run them from Paperclip to try them.

A `gate` that fails with the canary intact and nothing in the log means the
model declined on its own, so the deny list wasn't exercised.

With `--by-hand`, `ask` and `approve` wait for you to answer from Telegram,
Discord or Paperclip instead of answering as the board, and the result
names the channel board-bridge saw the answer come from. The DM can arrive
before any of the test's checks, so these don't assume an order and leave
agent-watch's alerts to the run without it. Rejecting the approval ends
`approve` there and cancels its issue, since Paperclip only wakes the
agent on an approval.

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
(`agent-watch.nix`). Within seconds of a change in Paperclip (see Live events),
and every five minutes anyway, it reads Paperclip and keeps these
alerts in Alerta on lab118-services, environment `Homelab`, origin
`agent-watch`:

| Event | Resource | When | Severity |
|---|---|---|---|
| `RunFailed` | `paperclip/<agent>` | the agent is in error, or its last finished run failed or timed out | minor |
| `IssueStuck` | `paperclip/LAB-<n>` | in progress for an hour with no run and no activity | warning |
| `ApprovalWaiting` | `paperclip/approval-<id>` | an approval waits on the board; links to it | warning |
| `WaitingOnYou` | `paperclip/LAB-<n>` | an open issue has a question the board hasn't answered, or you left it blocked on the board yourself; links to the issue | warning |
| `MarkedChange`, `MarkedSensitive` | `paperclip/LAB-<n>` | an open issue carries that label | warning |
| `BudgetWarning` | `paperclip/budget-<id>` | a budget is past its warning level, or stopped (major) | warning |
| `ClaudeSpend` | `anthropic/credits` | this month's estimated Claude spend across the agents has passed 80% of the month's credit, or all of it (major) | warning |
| `ClaudeCreditsOut` | `anthropic/credits` | Claude refused an agent for credits and hasn't worked for it since; the agent is on its fallback | major |
| `JevCreditsOut` | `typesafe/credits` | the same for Jev; agents carry on without it | major |
| `IntakeStale` | `n8n/intake` | an alert n8n should have handed to the monitor's triage has been open 15 minutes without it, and isn't waiting behind a triage open less than an hour; it names the alerts, and the triage it waits behind if that's been open an hour | warning |
| `BridgeStale` | `agents/board-bridge` | board-bridge hasn't read Paperclip and reached every chat channel that's on for 15 minutes, with the reason it last gave | warning |
| `EventsStale` | `agents/paperclip-events` | paperclip-events has been disconnected from Paperclip's live events for 5 minutes, so everything above waits for its timer, with the reason it last gave | warning |

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
| `agent-watch/paperclip-key` | a second Paperclip key on the researcher, named `agent-watch`. `scripts/agents/paperclip-agent-key.py agent-watch` makes a new one. |
| `paperclip-events/paperclip-key` | paperclip-events' key on the researcher, named `paperclip-events`, with no scope, since the live events refuse a scoped key. `scripts/agents/paperclip-agent-key.py paperclip-events` makes it and writes it here. |
| `agent-watch/alerta-key` | an Alerta API key with `read:alerts` and `write:alerts` |
| `agent-watch/kuma-push-url` | the `JOB / agent-watch` push monitor's URL |
| `root/console-password-hash` | `mkpasswd -m yescrypt` |
| `hermes/<name>/api-server-key` | `openssl rand -hex 32`, one per agent. Also goes into Paperclip as that agent's adapter `apiKey`. |
| `hermes/<name>/paperclip-key` | the agent's Paperclip key, only for agents listed in `withPaperclipKey`. |
| `inference/agents-key` | the agents' key for inference, the same value as `inference/keys/agents` in `secrets/hosts/inference.yaml` |
| `anthropic/api-key` | an Anthropic API key from the Console's Default workspace, capped only by the organization's limit and credits. Never an OAuth token. |
| `jev/api-key` | a TypeSafe API key, from console.typesafe.ai |
| `observe/proxmox-token` | the agents' Proxmox API token, `agents@pve!observe=<secret>`, audit-only |
| `observe/beszel-password` | the password of Beszel's readonly user for the agents |
| `observe/alerta-key` | an Alerta key with `read:alerts` only |
| `paperclip/board-bridge-key` | board-bridge's board key, named `board-bridge`, with no expiry. `scripts/agents/paperclip-board-key.py` makes it and writes it here. |
| `board-bridge/telegram-token` | the Telegram bot's token, from BotFather |
| `board-bridge/discord-token` | the Discord bot's token, from its application's Bot page. It needs no privileged intents. |
| `observe/github-token` | a fine-grained GitHub token from Justin's account: all repositories, read-only Metadata, Contents, Issues, Pull requests and Commit statuses |
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
- Six agents at their 2 GB `MemoryMax` plus Paperclip's 4 GB add up to more
  than the VM's 12 GB. Those are caps, and an idle agent uses far less, but
  several long runs at once could press on memory.
- GitHub's MCP server is pinned in the repo, not in nixpkgs, so its updates
  are by hand (`modules/roles/hermes-agents/github-mcp/package.nix`), and its
  `go.mod` is edited to build with nixpkgs' Go until that catches up.
- Kuma's status page and Alerta go over plain HTTP on the LAN as far as the
  router, then over the tunnel, like agent-watch's alerts.
- An alert waits 3 minutes for n8n's settle, and up to 5 minutes more after
  an earlier triage ends. The monitor and the researcher share the
  `agents` key's two requests at a time on inference with every agent's side
  tasks.
- board-bridge holds a board key, the most powerful kind there is; its
  route list is the only thing narrowing it.
- paperclip-events hears only what the researcher may read, which today is
  everything. While it's disconnected the services wait for their timers,
  so a question can take up to 5 minutes to reach the chat channels.
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
