# dashboard

dashboard is the lab's monitoring dashboard: a NixOS VM on the Proxmox
cluster that runs Homarr (the dashboard itself) and the Beszel hub (host, GPU
and service metrics with history). It's meant to answer "is anything broken,
overloaded or waiting on me?" from one page, and to keep answering it while a
Proxmox node is down or the WAN is out.

Uptime Kuma (on lab118-services) still owns availability checks and the alert
pipeline (Alerta, Apprise, ntfy) still owns delivery. This host adds the
resource view and puts everything on one board.

## At a glance

| | |
|---|---|
| VM | Proxmox, 2 vCPU (`x86-64-v2-AES`), 4 GB, 40 GB on `nas-shared`, MAC `02:01:18:00:00:05`, HA resource |
| Dashboard | `https://dashboard.servicestack.xyz` (Homarr 2.10.1, pinned by digest) |
| Metrics | `https://beszel.servicestack.xyz` (Beszel hub 0.18.7 from nixpkgs) |
| Login | `ssh dashboard` as `justin`, key only (the Mac Mini key). Root has no SSH. |
| Console | Proxmox console, root password from SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/dashboard.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Backups | Nightly at 03:15, NFS share on the NAS, age-encrypted, Kuma push monitor |

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/dashboard/configuration.nix` | The host: users, SOPS, Docker, Homarr, the Beszel agent, and the exposure assertions. |
| `hosts/dashboard/beszel-hub.nix` | The hub, its fixed UID, and the identity key placed from SOPS. |
| `hosts/dashboard/endpoints.nix` | ACME (Porkbun DNS-01), nginx vhosts and allow-lists, and what Pangolin may reach. |
| `hosts/dashboard/nginx/homarr-guard.conf` | The locations that keep Homarr's MCP and OAuth routes unreachable. |
| `hosts/dashboard/backup.nix` | The NFS mount and what gets backed up. |
| `hosts/dashboard/eval-test.nix` | Example values for the flake checks, not used by the real host. |
| `infra/terranix/hosts/dashboard.nix` | The VM, its storage, CPU type and HA resource. |
| `modules/roles/homarr.nix` | Homarr in Docker, the key guard and the health watch. |
| `modules/roles/beszel-agent.nix` | The agent every monitored host uses. |
| `modules/roles/sqlite-backup.nix`, `modules/roles/sqlite-backup/` | Consistent SQLite backups and restore, and their tests. |
| `scripts/dashboard/` | Health report, MCP probe, and `homarr-apply.py` with its spec. |
| `scripts/provisioning/proxmox-plan-guard.jq` | Refuses Proxmox plans that would delete or replace anything. |

## How it's reached

Both names exist twice. In the LAN and over the road-warrior VPN, AdGuard
rewrites `dashboard.servicestack.xyz` and `beszel.servicestack.xyz` to the VM,
and nginx on the VM serves them with a Let's Encrypt certificate. That
certificate comes through Porkbun DNS-01, since nothing on the Internet can
reach the VM. This path works when the WAN is down. From anywhere else the
same names resolve to Pangolin, which asks for SSO and then comes in through
the home site's Newt (the `pangolin-newt` VM, `10.0.0.72`). It reaches the VM
over HTTPS like any other LAN client and lands on the same server blocks.

Homarr needs this single origin. `BASE_URL` drives its secure cookies, origin
checks and redirects, so a plain-HTTP LAN address next to an HTTPS one
doesn't work.

| Path | Who may use it | Goes to |
|---|---|---|
| `dashboard.servicestack.xyz` `/` | LAN (Pangolin included), VPN | Homarr, `127.0.0.1:7575` |
| `dashboard.servicestack.xyz` `/api/health/live` | LAN, VPN, the tunnel (Kuma) | Homarr's health check |
| `beszel.servicestack.xyz` `/api/beszel/agent-connect` | LAN except Pangolin, the tunnel (lab118's agent) | the hub's agent WebSocket |
| `beszel.servicestack.xyz` `/_/` | LAN except Pangolin, VPN | PocketBase's superuser UI |
| `beszel.servicestack.xyz` everything else | LAN (Pangolin included), VPN, Homarr's container | the hub, `127.0.0.1:8090` |
| unknown names, bare IP | nobody | no certificate, no content |

Pangolin's traffic comes from inside the LAN range, so the two paths that
must not be reachable remotely start with `deny 10.0.0.72`. nginx takes the
first matching rule, and an assertion in `endpoints.nix` fails the build if
that deny isn't first.

The firewall opens TCP 22, 80 and 443 and nothing else. Containers publish on
127.0.0.1 only, and the hub listens on 127.0.0.1. The assertions in
`configuration.nix` and `endpoints.nix` fail the build if any of that changes,
and `.#checks.<system>.dashboard-exposure-guards` proves they fire.

Homarr's MCP endpoint (`/api/mcp`), its OAuth routes (`/api/mcp/oauth/*`,
`/.well-known/*`) and the page that approves MCP clients (`/<locale>/auth/mcp`)
return 404 for everyone, Pangolin included. `scripts/dashboard/probe-mcp-block.sh`
checks that from the LAN; it only accepts nginx's 404.

### DNS and router settings this depends on

These live outside the repo:
- AdGuard rewrites for both names to the VM's address.
- An OPNsense DHCP reservation for `02:01:18:00:00:05`. The MAC is fixed in
  Terraform, so the address follows the VM through migration and HA recovery.
- A `WG_LAB118` rule passing TCP 443 from `10.118.0.1` to the VM, for Kuma's
  checks and lab118's Beszel agent.
- Porkbun API access enabled for `servicestack.xyz`. A Porkbun key works on
  every domain that has API access turned on, so leave it off elsewhere.
- Pangolin: two resources on the home site, `dashboard.servicestack.xyz` and
  `beszel.servicestack.xyz`. Each targets `https://10.0.0.151:443`, with its
  TLS server name (SNI) set to the resource's own name, and SSO on. Without
  the SNI, nginx refuses the handshake (it only has certificates for the two
  names) and Pangolin shows Bad Gateway; an `http` target gets nginx's "plain
  HTTP request was sent to HTTPS port".

LAN clients only take the direct path when AdGuard answers them. A second,
public DNS server on the client, or the browser's own secure DNS, sends them
through Pangolin instead.

lab118-services resolves the two names through lab DNS over the tunnel
(`labDomains`), not through public DNS, because Pangolin's SSO would stop its
agent and Kuma's checks.

Remote access depends on the home site's Newt as well as the VM: HA can bring
the dashboard back on another node, but from outside it stays unreachable
while `pangolin-newt` is down. The LAN path doesn't depend on it.

## Monitoring, and what does what

| Tool | Job | Where |
|---|---|---|
| Uptime Kuma | Is a service up, how fast, certificate expiry, incidents | lab118-services, outside the lab |
| Beszel | CPU, memory, disk, network, GPU, systemd units, 30 days of history, threshold alerts | hub here, agents on each host |
| Kuma push monitors | Scheduled jobs that must check in (backups, the hub's heartbeat, the router's heartbeat) | lab118-services |
| Alerta, Apprise, ntfy | Where alerts go and how they reach the phone | lab118-services |
| Homarr | One page over all of the above plus Proxmox, OPNsense and AdGuard | here |

Netdata isn't deployed, so Beszel doesn't replace anything. The old Checkmk
VM is untouched. There's no Prometheus or Grafana; if one is ever needed,
Beszel's history and the Homarr integrations don't have to change.

There's no Healthchecks instance. Jobs report to Kuma push monitors instead,
the same way the router heartbeat does.

Kuma watches this host over the tunnel:

| Monitor | Check | Down means |
|---|---|---|
| `SVC / dashboard` | HTTP `https://dashboard.servicestack.xyz/api/health/live`, expect 200 | Homarr, nginx or the VM is down (or the tunnel) |
| `SVC / beszel` | HTTP `https://beszel.servicestack.xyz/api/health`, expect 200 | the hub is down |
| `JOB / dashboard backup` | push, 26 h heartbeat (`kuma/backup-push-url`) | the nightly backup failed or didn't run |
| `JOB / beszel heartbeat` | push (`kuma/beszel-heartbeat-url`) | the hub stopped running or can't reach the Internet |

Beszel alerts should go into the existing pipeline rather than straight to
the phone. Point a Beszel notification at Node-RED's intake on lab118 over the
tunnel (shoutrrr generic webhook to `http://10.118.0.1:1880/intake/beszel`,
JSON template), and have a Node-RED flow turn it into an Alerta alert. Send a
test notification first to see the exact payload. The flow lives in
Node-RED, not here.

## Homarr

The role is `modules/roles/homarr.nix`. Things worth knowing:

- Everything lives in `/var/lib/homarr` (`/appdata` in the container): the
  SQLite database (`db/db.sqlite`, journal mode `delete`), a Redis snapshot
  and `trusted-certificates/`. The Redis data is cache and job state.
- The container runs as UID 7575 (`PUID`/`PGID`) with `no-new-privileges`,
  no Docker socket and `ENABLE_DOCKER=false`.
- `SECRET_ENCRYPTION_KEY` encrypts every integration credential in the
  database. It's mounted read-only and read through
  `SECRET_ENCRYPTION_KEY_FILE`, so `docker inspect` never shows it.
- Before every start, the key guard checks the key is 64 hex characters and
  compares its sha256 with `/var/lib/homarr/.secret-encryption-key.sha256`,
  which is written on first start. A different key stops Homarr instead of
  letting it start with credentials it can't read.
- systemd restarts the container whenever it stops. `homarr-health-watch`
  also restarts it when Docker's health check (`/api/health/live`, which
  checks the database and Redis) stays unhealthy, at most once per 15
  minutes.
- `NO_EXTERNAL_CONNECTION=true` stops update checks, weather, RSS and
  analytics. It doesn't cover the Assistant or the Workshop, which onboarding
  reports as reachable.
- API keys belong to the admin who makes them and can do everything that admin
  can. Make one only for `homarr-apply.py`, then delete it.

Homarr's CLI needs the key in its environment, because only the container's
entrypoint reads `SECRET_ENCRYPTION_KEY_FILE`:

```sh
sudo docker exec homarr sh -c \
  'SECRET_ENCRYPTION_KEY="$(cat /run/secrets/homarr-secret-encryption-key)" homarr users list'
```

The commands print their result and then don't exit; press Ctrl-C. Useful
ones: `users list`, `reset-password --username <name>`,
`users update-password -u <name> -p <password>`, `recreate-admin --username <name>`,
`integrations list`.

## Integrations

Homarr stores integration credentials encrypted in its database, and they're
entered in its UI. Use a dedicated, least-privilege account for each.

| Service | Widgets | Account | URL from Homarr |
|---|---|---|---|
| Proxmox VE | health monitoring (nodes, VMs, LXCs, storage) | `homarr@pve` with a privilege-separated token, `PVEAuditor` on `/` | a node's `https://<node>:8006`, its CA in trusted certificates |
| Uptime Kuma | status, uptime, response time, certificate expiry | none (a public status page) | `http://10.118.0.1:3002`, slug of the status page |
| Beszel | systems grid and table, time series, alerts | a `readonly` hub user | `https://beszel.servicestack.xyz` |
| OPNsense | CPU, memory, interface traffic | API key for a user with only "Lobby: Dashboard" and "Reporting: Traffic" (needs OPNsense 25.7 or later) | `http://10.0.0.1`; the GUI is plain HTTP, so no certificate |
| AdGuard Home | DNS summary, protection on and off | there are no read-only users; any login is admin | `http://10.0.0.1:3000` |
| Home Assistant | entity state, toggles, automations | long-lived token from a non-admin user (it can still call any service) | the HA URL |
| Navidrome | library, streams | a non-admin user | |
| slskd | downloads | an API key with role `readonly` in slskd's config | |
| llama.cpp | health, models, metrics | none (start it with `--metrics`) | |

There's no native integration for Omada, AMP, Ollama monitoring or the agent
services (Hermes, OpenClaw, Paperclip). They're links for now; a Custom API
widget can fill the gap later. GPU usage of the RTX 3090 comes from the Beszel
agent on `ollama`. Homarr's Assistant can use the local Ollama as an
OpenAI-compatible provider (`http://10.0.0.63:11434/v1`) instead of Homarr's
hosted one.

The Proxmox account, on any node:

```sh
pveum user add homarr@pve --comment "Homarr dashboard, read-only"
pveum acl modify / --users homarr@pve --roles PVEAuditor
pveum user token add homarr@pve dashboard --privsep 1
pveum acl modify / --tokens 'homarr@pve!dashboard' --roles PVEAuditor
```

The widget asks one node for `/cluster/resources`, so it goes blank while
that node is down. Pick the node that's least likely to be in maintenance, or
a name you can repoint.

The Kuma status page is readable from the lab through a tunnel-only vhost on
lab118 (port 3002, GET under `/api/status-page/` only). Build a status page
in Kuma with the monitors you want on the dashboard and use its slug.

## Boards

`scripts/dashboard/homarr-apply.py` creates the boards and the app catalog
from `scripts/dashboard/homarr-spec.json` through Homarr's documented REST
API, and is safe to run again. It doesn't place widgets: Homarr has no
supported way to build board content declaratively, so layouts are made in
the UI. A backup is the golden copy afterwards.

```sh
scripts/dashboard/homarr-apply.py            # dry run, prompts for an API key
scripts/dashboard/homarr-apply.py --apply
```

Apps whose `href` is still `TODO` in the spec are skipped; fill in the URL to
include them.

| Board | What goes on it |
|---|---|
| `Home` (home) | Kuma status page, Beszel alerts and systems grid, Proxmox health, OPNsense, DNS summary, admin links |
| `infrastructure` | Proxmox nodes, VMs and storage, Beszel time series per host, Kuma's backup push monitors |
| `network` | OPNsense, AdGuard, Kuma's network monitors (tunnel, WAN, DNS), Omada and VPN links |
| `services` | Kuma, apps grouped by purpose |
| `ai-infrastructure` | Beszel GPU stats for `ollama`, Ollama and agent links |
| `media-gaming` | Navidrome, slskd and AMP links |

## Beszel

The hub keeps its data in `/var/lib/beszel-hub/beszel_data` (PocketBase
SQLite, WAL) as UID 8090. Its identity key (`id_ed25519`) comes from SOPS
(`beszel/hub-private-key`) and is installed before each start, so every agent
can be configured with the public key, and a rebuilt VM is still the same hub
to them. The public key is:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMOw68emIRvFIytDPVQbJRS0et+o1KedYFcvQvo6qv6v
```

Agents connect to the hub over WebSocket with `DISABLE_SSH=true` and listen on
nothing. `roles.beszelAgent` sets them up:
- `KEY` is the hub's public key, the role's `hubPublicKey`, which defaults
  to this hub's key. Setting it to null turns the agent off with a warning.
- `TOKEN` is a permanent universal token from the hub (Settings, Tokens),
  kept in SOPS as `beszel/agent-token`.

The agent runs on dashboard, dockhand, pr-previews, ollama and
lab118-services. It gets no Docker access. Container stats would need the
Docker API, and the calls the agent makes expose every container's
environment, so they're off. On `ollama` the role passes through the NVIDIA
device nodes, and only those.

The hub has three kinds of account. The admin you create first, a `readonly`
user for Homarr, and PocketBase superusers. Create the readonly user as a
superuser in `/_/` (users collection, new record, role `readonly`, verified).
The email has to be a real address; it's
`hello+beszelhomarr@justin-arnold.com`, and Homarr signs in with it.
`SHARE_ALL_SYSTEMS=true` lets it see every system.

The Proxmox hosts aren't NixOS, so their agents are installed by hand from the
release `.deb` of the same version as the hub:
- Put `KEY`, `TOKEN`, `HUB_URL=https://beszel.servicestack.xyz` and
  `DISABLE_SSH=true` in `/etc/beszel-agent.conf`, mode 0600.
- Leave the `beszel` user out of the `disk` group unless you want S.M.A.R.T.
  data; on a hypervisor that group can read every VM disk.
- Don't enable the auto-update timer.

## Secrets

`secrets/hosts/dashboard.yaml` is encrypted to the host's own age key and the
operator key, nothing else.
On macOS, sops doesn't look in `~/.config/sops/age`, so edit it with
`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/dashboard.yaml`.

| Key | What |
|---|---|
| `homarr/secret-encryption-key` | `openssl rand -hex 32`. Never change it; keep a copy in 1Password. |
| `beszel/hub-private-key` | the private half of `ssh-keygen -t ed25519 -N '' -C beszel-hub` |
| `beszel/agent-token` | the hub's universal token, added after the hub's first start |
| `porkbun/api-key`, `porkbun/secret-api-key` | for DNS-01 |
| `kuma/backup-push-url` | push monitor for backups |
| `kuma/beszel-heartbeat-url` | push monitor the hub pings while it's healthy |
| `root/console-password-hash` | `mkpasswd -m yescrypt` |

The host key is installed by `nix run .#install` from `HOST_AGE_KEY_FILE`
(`hostAgeKey = true` in `infra/terranix/default.nix`). Install refuses the
operator key, a key that isn't in `.sops.yaml`, a file it can't decrypt with
the host key, and any value still set to `pending`. Until the file exists the
real host fails to build with a message saying so.

dockhand, pr-previews and ollama read their agent token from
`secrets/secrets.yaml`, and lab118-services from its own host file.

## Backups

`roles.sqliteBackup` runs at 03:15 (plus up to 10 minutes):
- It snapshots Homarr's database and the hub's `data.db` with SQLite's online
  backup, each as its file's owner.
- It checks their integrity.
- It packs them with the key fingerprint and Homarr's trusted certificates.
- It encrypts the archive to the host and operator keys and writes it to
  `/mnt/dashboard-backups` (NFS, mounted on demand, `soft`).
- It reads the archive back, keeps 30 days (never fewer than 7 archives),
  and reports up or down to `kuma/backup-push-url`.

Set the push monitor's heartbeat interval to 26 hours.

```sh
sudo systemctl start sqlite-backup     # a backup now
sudo sqlite-backup list                # archives, newest first
sudo journalctl -u sqlite-backup
```

The export is `10.0.0.20:/mnt/Main/backups/dashboard-backups` on TrueNAS
(`dashboard.backup.nfsDevice`). The share only accepts the VM's address and
maps root to root, so the job can write and prune its archives.

The NAS holds both the VM's disk and the backups, so it can lose both at once.
It replicates to a second TrueNAS on site, which covers a dead NAS but not
losing the site; an off-site copy is planned. Proxmox's own backups (vzdump or
PBS) of the VM aren't managed here.

## HA and Proxmox

What the repo sets: the VM's storage (disk and cloud-init drive on
`nas-shared`), its CPU type, MAC, the HA resource (`proxmox_haresource`), and
provisioning that refuses to delete or replace a VM and finds it on whichever
node it runs.

What lives on the cluster and has to be true there:

```sh
pvecm status                          # quorate, 5 votes, quorum 3
ha-manager status                     # vm:<id> started, the CRM has a master
pvesm status --storage nas-shared     # active, on every node
qm config <vmid> | grep -E 'scsi|ide|cpu|net'   # every disk on nas-shared, cpu x86-64-v2-AES
journalctl -u watchdog-mux -b | tail  # watchdog loaded (softdog unless set otherwise)
```

All five nodes need `vmbr0` with the same uplink, and `nas-shared` mounted. On
PVE 9 HA groups became rules. No rule is needed while every node is eligible;
`ha-manager rules add node-affinity` limits the VM to some nodes if that
changes.

What to expect:
- Live migration copies memory while the VM runs, then pauses it briefly to
  switch over. Connections usually survive.
- If a node dies, the cluster waits for it to fence itself (about a minute),
  then starts the VM on another node. Expect two to three minutes without the
  dashboard. It boots from the same disk, as after a power cut. SQLite
  rolls back unfinished writes; anything Homarr held only in memory and the
  last minute of Redis state are gone.
- If the application crashes, systemd restarts it within seconds; a hang is
  caught by the health watch.
- With shared storage there's no replication interval to lose. The nightly
  backup is for mistakes and for losing the NAS.

`notifications`, the earlier HA VM on `nas-shared`, was created before
`cloudInitDatastore` existed, so its cloud-init drive is probably on
`local-lvm`. That would stop HA moving it.

True application-level HA (two Homarr instances) would need PostgreSQL with
failover instead of SQLite, a highly available Redis, a load balancer with
health checks, and the same encryption key on both. It isn't worth it for a
dashboard.

## Operations

### Planned maintenance on a node

```sh
ha-manager crm-command node-maintenance enable <node>   # HA moves its VMs away
# ... work on the node, reboot ...
ha-manager crm-command node-maintenance disable <node>  # VMs may move back
```

Or move just this VM: `ha-manager migrate vm:<id> <node>`. After a move,
`nix run .#switch -- dashboard` still works; it finds the VM's current node.

### A node failed

Nothing to do if HA is healthy: `ha-manager status` shows the VM going through
`fence` and `recovery` to `started` on another node. If it ends up in `error`
(the retries ran out), fix the cause, then
`ha-manager set vm:<id> --state disabled` and `--state started`. Then run
`scripts/dashboard/post-install-check.sh`.

### The application misbehaves

```sh
sudo systemctl restart docker-homarr     # or beszel-hub
sudo journalctl -u docker-homarr -n 100
sudo docker inspect --format '{{.State.Health.Status}}' homarr
```

If Homarr won't start and the journal says the key doesn't match, the SOPS
value changed. Put the original key back; don't move the data aside unless
you mean to start over.

### Rebuilding the VM

`nix run .#provision -- dashboard` with `HOST_AGE_KEY_FILE` and
`SSH_PRIVATE_KEY_PATH=~/.ssh/homelab_provision` set recreates the VM and
installs it. Then restore the newest backup (below). With the same host key,
everything from SOPS comes back on its own, including the hub's identity.

The bootstrap key goes into the new VM's cloud-init and is never changed
afterwards, so a VM created with the wrong one has to be destroyed
(`nix run .#destroy -- dashboard`) and created again.

### Restoring a backup

```sh
sudo sqlite-backup list
sudo sqlite-backup restore /mnt/dashboard-backups/dashboard-<time>.tar.zst.age
```

The restore:
- decrypts the archive with the host key (`SQLITE_BACKUP_IDENTITY=<file>`
  uses another one, such as the operator key on a different machine);
- checks every database;
- refuses an archive whose key fingerprint doesn't match the current key;
- stops Homarr and the hub, keeps the replaced files as
  `*.pre-restore-<time>`, and starts both again.

On a fresh VM, let Homarr start once first so the key guard writes its
fingerprint. `--force` restores despite a mismatch, but Homarr then refuses to
start until the original key is back.

### Upgrading

For Homarr, read the release notes, run `sudo systemctl start sqlite-backup`,
change the image digest in `hosts/dashboard/configuration.nix`, then switch.
Rolling back means the previous digest and restoring the pre-upgrade backup,
because migrations only go forward.

Beszel comes from nixpkgs, so it moves with `nix flake update`. Keep the
Proxmox hosts' agents on the same version.

## MCP and agents

Homarr 2.x has an MCP server at `/api/mcp` (Streamable HTTP). It
authenticates two ways:
- With an API key, which is admin-level.
- With OAuth 2.1, where any signed-in Homarr user can approve a client and
  the client gets that user's permissions.

Its tools include writes: boards, apps, integrations, users, AdGuard on and
off, Home Assistant switches and automations, and `integration_request`, which
makes arbitrary calls to any configured integration. Homarr has no switch to
turn MCP off, which is why nginx blocks it everywhere.

For Hermes or OpenClaw later:
- Create a dedicated Homarr user with view-only permissions and connect it
  through OAuth, not an API key.
- Expose `/api/mcp` on a separate listener allowed only from the agent host,
  never through Pangolin.
- Start with read tools only, and require explicit approval before any write
  tool is reachable.
- Update the guard, the assertions and the probe together when you do.

## Known limits

- The OPNsense integration needs 25.7 or later. Homarr calls
  `/api/diagnostics/system/system_information` and `system_resources`, and
  before 25.7 the "Lobby: Dashboard" privilege only covers the camelCase
  spellings (`systemInformation`), so those calls get 403. Only "All pages"
  would cover them, which makes the key an admin key.
- Beszel 0.18.7 lacks failed-systemd alerts and ZFS pool stats (0.19+). Its
  history goes back 30 days at most.
- Container stats are off on every agent.
- Homarr's Proxmox widget depends on the one node it asks.
- Board layouts aren't in the repo; backups are.
- The VM and its backups share one NAS. The second TrueNAS is on site, so
  nothing is off site yet.

## Gotchas

- The first visitor to a fresh Homarr or Beszel becomes its admin. Finish
  both setups before adding the Pangolin resources.
- Onboarding turns on Homarr's analytics and its hosted Assistant by default.
  Switch analytics off. The Assistant is on here; what you ask it goes to
  Homarr's hosted service until it's pointed at Ollama (above). Onboarding
  also adds four sample apps (Homarr Docs, GitHub, Help Translate, Support).
- Inside the Homarr container, Redis and Next.js listen on all addresses
  without authentication. That's only safe because nothing shares the
  container's network namespace or publishes those ports; keep it that way.
- Homarr stores the Beszel username as a secret too, so it shows masked.
- `docker exec homarr homarr ...` fails with "SECRET_ENCRYPTION_KEY is required"
  unless you pass the key as shown above.
- AdGuard has no read-only accounts. The DNS Hole Controls widget can turn
  filtering off for the whole network.
- systemd 260 id-maps any service state directory owned by `nobody`, and
  leaves it that way after DynamicUser is turned off. The hub's data has to
  belong to `beszel-hub`, or the backup refuses it. If it ever shows up as
  `nobody`, stop the hub, `chown -R beszel-hub:beszel-hub /var/lib/beszel-hub`,
  and start it again.

## Related

- `docs/lab118-services/REFERENCE.md`: Uptime Kuma, the alert pipeline, the
  WireGuard tunnel and the status-page listener on port 3002.
- `readme.md`: the provisioning commands.
