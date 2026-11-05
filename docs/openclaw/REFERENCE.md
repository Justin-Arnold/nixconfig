# openclaw

openclaw is the chat front door to the lab's agents: a NixOS VM on the
Proxmox cluster running an OpenClaw gateway as the concierge. Justin tells
it what he wants done, and it files the work in Paperclip for the
coordinator, follows it and reports back. The work itself happens elsewhere:
the coordinator and the specialists are Hermes agents on the agents VM, and
their code runs on workbench.

Paperclip is the concierge's only tool. It can't run commands, read or write
files, browse, search the web, install skills or change its own setup, and
approvals stay in Paperclip's own UI, where only Justin can give them. The
host holds the concierge's ChatGPT login, its Paperclip key and the chat
bots' tokens, and nothing else.

## At a glance

| | |
|---|---|
| VM | Proxmox, 2 vCPU (`x86-64-v2-AES`), 4 GB, 30 GB on `nas-shared`, MAC `02:01:18:00:00:08`, HA |
| Address | `10.0.0.154` (DHCP reservation) |
| Name | `openclaw.servicestack.xyz`, LAN and VPN directly, elsewhere through Pangolin with SSO |
| Gateway | OpenClaw 2026.10.7 from nix-openclaw, as `openclaw` (uid 3401), on `127.0.0.1:18789` |
| Login | `ssh openclaw` as `justin`, key only (the Mac Mini key). Root has no SSH. |
| Console | Proxmox console, root password from SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/openclaw.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Backups | nightly to `10.0.0.20:/mnt/Main/backups/openclaw-backups` |

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/openclaw/configuration.nix` | The host: SOPS, the egress filter, the Beszel agent, and the exposure assertions. |
| `hosts/openclaw/openclaw.nix` | The concierge: its settings, Paperclip tools, channels and secrets. |
| `hosts/openclaw/workspace/` | `AGENTS.md`, `SOUL.md` and `IDENTITY.md`, its instructions. |
| `hosts/openclaw/endpoints.nix` | nginx and the certificate. |
| `hosts/openclaw/backup.nix` | The nightly backup. |
| `hosts/openclaw/eval-test.nix` | Example values for the flake checks, not used by the real host. |
| `modules/roles/openclaw.nix` | The gateway's unit, its config file and `openclaw-admin`. |
| `infra/terranix/hosts/openclaw.nix` | The VM, its storage and the HA resource. |
| `modules/roles/hermes-agents/paperclip-mcp/` | The Paperclip MCP server, shared with the Hermes agents. |

## How it's reached

It works like the agents VM. In the LAN and over the VPN, AdGuard rewrites
`openclaw.servicestack.xyz` to the VM, and nginx serves it with a Let's
Encrypt certificate from Porkbun DNS-01. From anywhere else the name
resolves to Pangolin, which asks for SSO and comes in through the home
site's Newt like any other LAN client.

| Path | Who may use it | Goes to |
|---|---|---|
| `/readyz` | LAN, VPN, the tunnel (Kuma) | the gateway's readiness check |
| everything else | LAN (Pangolin included), VPN | the Control UI and the gateway's WebSocket |
| unknown names, bare IP | nobody | no certificate, no content |

Past nginx, the gateway wants its token, and every new browser or client is
a device that has to be paired once. The Control UI asks for the token as
the "Gateway secret" and keeps it for that tab only. A browser's pairing
request waits until it's approved on the host with `openclaw-admin devices`.

The gateway trusts only this host's nginx as a proxy, and nginx replaces
`X-Forwarded-For` with the client's own address, so a client can't pose as
another or as loopback. That's why `recommendedProxySettings` is off here:
its headers would pass on what the client sent.

The firewall opens TCP 22, 80 and 443 and nothing else. The assertions in
`configuration.nix` and `endpoints.nix` fail the build if any of this
changes, and `.#checks.<system>.openclaw-exposure-guards` proves they fire.

### DNS and router settings this depends on

These live outside the repo:
- An AdGuard rewrite for `openclaw.servicestack.xyz` to `10.0.0.154`.
- An OPNsense DHCP reservation for `02:01:18:00:00:08` at `10.0.0.154`.
- A `WG_LAB118` rule passing TCP 443 from `10.118.0.1` to the VM, for Kuma's
  check.
- Optionally a Pangolin resource on the home site for
  `openclaw.servicestack.xyz`, targeting `https://10.0.0.154:443` with the
  TLS server name set and SSO on, for the Control UI away from home.

## The gateway

nix-openclaw's NixOS module writes the config world-readable under `/etc`
and sets no hardening at all, so `modules/roles/openclaw.nix` runs the
gateway from nix-openclaw's `openclaw-gateway` package with its own unit.
That package leaves out the extra tools nix-openclaw's default puts on the
PATH (git, curl, python and others).

The config comes from `roles.openclaw.settings`, whose type is OpenClaw's
own config schema. nix-openclaw generates it as Nix options for the release
it packages, so a misspelt key or a value the gateway would refuse fails
evaluation, not the gateway's start. On every start the file is copied into
`/var/lib/openclaw/openclaw.json` readable by `openclaw` only, along with the
workspace files, and `OPENCLAW_NIX_MODE` stops the gateway from changing its
config, installing anything or updating itself. Secrets never go in it.
They're `${VAR}` references, filled from `/run/secrets/rendered/openclaw.env`,
which only root can read and systemd hands to the gateway.

The unit has no capabilities, a read-only system, a private `/tmp` and
devices, a 2 GB memory limit and the usual syscall filter. Its state
directory is `0700`, and its logs go to the journal and
`/var/lib/openclaw/logs/`.

`sudo openclaw-admin <args>` runs the OpenClaw CLI as `openclaw` with the
same config and secrets. It's how pairings are approved, the ChatGPT login is
made and `openclaw security audit` is run.

## What the concierge can do

Its tools are OpenClaw's `minimal` profile, which is only `session_status`
and `gateway`, plus the Paperclip MCP server (`bundle-mcp`). `gateway`, which
can update OpenClaw and read its config, is denied, along with the
`openclaw` delegation tool, plugins, cron, the skill workshop, the browser,
spawning or messaging other sessions, and the runtime, file, web, UI,
automation, node and media groups. Exec is set to `deny`, elevated is off,
web search and fetch are off, and hooks are off, so nothing from outside
reaches the agent unless Justin sends it.

No skills load, bundled or otherwise, and OpenClaw's install policy refuses
every skill and plugin install. Nothing runs in a sandbox, because there's
nothing to sandbox. The Control UI's terminal, which would open a shell on
this host, is off.

Its instructions are `hosts/openclaw/workspace/AGENTS.md`, with the persona
in `SOUL.md`. They're copied in read-only on every start and OpenClaw's own
bootstrap is skipped, so the agent can't rewrite them. Its memory files sit
beside them in the workspace and are its own.

It runs on the ChatGPT plan, as `openai/gpt-6.1-sol` with `openai/gpt-6-sol`
as the fallback, on OpenClaw's own runtime. Codex's runtime would bring its
own shell and file tools. The login is separate from the Hermes agents'
(`sudo openclaw-admin models auth login --provider openai --device-code`)
but shares the plan's limits. The login also offers to loosen model
restrictions in `openclaw.json`, which Nix keeps read-only, so it ends with
"provider settings could not be applied". The login itself is saved.

## Paperclip

The concierge is an agent in Paperclip like the Hermes ones, with its own
agent key in `openclaw/paperclip-key`. Paperclip 2026.1023.0 doesn't offer
the OpenClaw adapter on its New Agent page; an OpenClaw agent joins through
an agent invite from the add-agent dialog instead. The invite expects the
agent to call Paperclip's API to accept it and later claim its key, which
the concierge has no way to do, so both calls are made by hand: accepting
with the adapter settings below, then, once the board approves the join
request in the Inbox, claiming the key straight into SOPS. The claim secret
from the accept is good for seven days and one claim. It reaches Paperclip at
`https://paperclip.servicestack.xyz` over the LAN, and the egress filter
lets the gateway's user reach the agents VM on port 443 and no other LAN
address. Its tools are the Paperclip MCP server's, limited to reading
agents, projects, goals, approvals, issues and comments, creating issues,
adding comments, and checking out and setting the status of issues assigned
to it. Paperclip wants every run it wakes an agent for to end with the
issue's status set, and refuses changes to another agent's issue, so the
concierge can close its own work but not touch the coordinator's. It can't
write documents or create approvals. Until `withPaperclipKey` is set in `openclaw.nix`, the
server isn't configured and the concierge has no tools.

Paperclip reaches it the other way with the `openclaw_gateway` adapter, to
wake it about an issue: `wss://openclaw.servicestack.xyz` with the gateway
token, the `operator` role with the `operator.write` scope only, sessions
per issue, and a device key Paperclip makes at the join, which is paired
once like a browser. The adapter in Paperclip 2026.1023.0 has a few
problems worth knowing:
- It sends its timeout in milliseconds where OpenClaw reads seconds, so
  OpenClaw would let a turn run far longer than meant. Paperclip's own wait
  timeout still ends the run on its side.
- Saving the agent's form writes the redacted placeholder over the token and
  device key, so after any edit they have to be entered again.
- Device keys Paperclip generates have failed to load for some users. If a
  run fails with a `DECODER` error, the agent needs one made with
  `openssl genpkey -algorithm ed25519` instead.
- Cancelling a run in Paperclip doesn't stop the turn in OpenClaw.

A wake lands in a session of its own for that issue, not in Justin's chat,
so the concierge's report on it shows in the Control UI's sessions until a
channel can carry it.

## Chat channels

WebChat is the Control UI's chat tab, and it's on from the start. Discord
and Telegram are declared but off. Each comes on when Justin's user id for
it is set (`openclaw.concierge.discordUserId`, `telegramUserId`) and its bot
token is in SOPS, and then the bot takes his DMs and nothing else: an
allowlist of that one id, no pairing and no groups. Messages on either pass
through those companies' servers, so secrets never go in chat.

## Monitoring

Beszel's agent reports the host. Kuma watches it over the tunnel:

| Monitor | Check | Down means |
|---|---|---|
| `SVC / openclaw` | HTTP `https://openclaw.servicestack.xyz/readyz`, expect 200 | the gateway, nginx or the VM is down (or the tunnel) |
| `JOB / openclaw backup` | push, 26 h heartbeat (`kuma/backup-push-url`) | the nightly backup failed or didn't run |

## Secrets

`secrets/hosts/openclaw.yaml` is encrypted to the host's own age key and the
operator key, nothing else. On macOS, edit it with
`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/openclaw.yaml`.

| Key | What |
|---|---|
| `root/console-password-hash` | `mkpasswd -m yescrypt` |
| `beszel/agent-token` | the hub's universal token |
| `porkbun/api-key`, `porkbun/secret-api-key` | for DNS-01 |
| `kuma/backup-push-url` | push monitor for backups |
| `openclaw/gateway-token` | `openssl rand -hex 32`. The Control UI's secret, and Paperclip's token for the adapter. |
| `openclaw/paperclip-key` | the concierge's Paperclip agent key, once `withPaperclipKey` is set |
| `openclaw/discord-token`, `openclaw/telegram-token` | the bots' tokens, once their user ids are set |

The host key is installed by `nix run .#install` from `HOST_AGE_KEY_FILE`
(`hostAgeKey = true` in `infra/terranix/default.nix`), the same way as on
the agents VM. Until `secrets/hosts/openclaw.yaml` exists, the real host
fails to build with a message saying so.

## Backups

`roles.sqliteBackup` takes the gateway's database (devices, pairings,
approvals and the ChatGPT login), the concierge's database (sessions and
memory), its workspace and the channels' credentials. It encrypts the archive
to the host and operator keys, writes it to `/mnt/openclaw-backups` (NFS,
mounted on demand, `soft`), reads it back, keeps 30 days and reports to
`kuma/backup-push-url`. The export should only accept the VM's address and
map root to root.

```sh
sudo systemctl start sqlite-backup     # a backup now
sudo sqlite-backup list                # archives, newest first
sudo sqlite-backup restore /mnt/openclaw-backups/openclaw-<time>.tar.zst.age
```

A restore stops the gateway, keeps the current databases beside the
restored ones, and starts it again.

## Operations

```sh
sudo systemctl restart openclaw-gateway
sudo journalctl -u openclaw-gateway -n 100
sudo openclaw-admin devices list
sudo openclaw-admin models status
sudo openclaw-admin security audit
```

Upgrading means a new nix-openclaw tag in `flake.nix` and `nix flake update
nix-openclaw`. The schema the settings are checked against moves with it, so
a key the new release dropped fails evaluation before anything is switched.
nix-openclaw has no binary cache, so the switch builds the gateway on the
VM.

Rebuilding the VM is `nix run .#provision -- openclaw` with
`HOST_AGE_KEY_FILE` and `SSH_PRIVATE_KEY_PATH` set, then a restore of the
newest backup, which brings back the login and pairings.

## Known limits

- The gateway token is the whole of the gateway's operator access, and
  Paperclip keeps it in its database for the adapter. Paperclip's company
  agents list also returns the adapter's device key in plain text to anyone
  who can read it, which is the board.
- OpenClaw has a long advisory history, including a one-click Control UI
  token leak fixed in 2026.1.29. The pinned release is far past it, but
  upgrades shouldn't wait long.
- Paperclip tasks marked private are invisible to the concierge unless
  they're shared with it.
- The config is checked against the schema of the release nix-openclaw
  packages, not the newest OpenClaw.
- The filter knows the LAN by its private IPv4 ranges and IPv6's local ones;
  a routed IPv6 LAN prefix would need adding.

## Related

- `docs/agents/REFERENCE.md`: Paperclip and the Hermes agents the concierge
  files work for.
- `docs/workbench/REFERENCE.md`: where their work runs.
- `readme.md`: the provisioning commands.
