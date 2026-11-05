# lab118-services

lab118-services is a small VPS at Contabo that keeps alerting working when the
lab doesn't. It runs the notification stack (Alerta, Apprise, ntfy, Node-RED)
and Uptime Kuma, watches the lab from the outside, and reaches into the lab
over a dedicated WireGuard tunnel to check individual services.

If the lab loses power or Internet, this box notices and your phone still gets
the alert over cellular.

## At a glance

| | |
|---|---|
| Provider | Contabo Cloud VPS 12 (product `V156`), EU, monthly. Instance `203635567` (`vmi3635567`) |
| Address | `89.117.73.89/21` via `89.117.72.1`, `2605:a144:2363:5567::1/64` via `fe80::1` |
| OS | NixOS unstable from this flake, `stateVersion` 26.05 |
| Login | `ssh lab118-services` as `justin`, key only (the Mac Mini key from 1Password). Root has no SSH. |
| Console | Contabo panel VNC, root password in 1Password ("lab118-services root console") |
| Dashboards | `alerta.`, `nodered.`, `kuma.servicestack.xyz`, through Pangolin with SSO |
| Public endpoints | `ntfy.lab118.xyz`, `intake.lab118.xyz`, straight to the VPS |
| Lab tunnel | `wg-lab`, cloud `10.118.0.1`, router `10.118.0.2`, routes `10.0.0.0/24` only |

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/lab118-services/configuration.nix` | The host. Pulls in the roles, wires secrets to services, sets image pins, and holds the exposure assertions. |
| `hosts/lab118-services/facts.nix` | Provider facts: IPs, gateway, MAC, disk. The build refuses to run if a required fact is `null`. |
| `hosts/lab118-services/networking.nix` | Static networkd config, public resolvers, the resolver stub for containers. |
| `hosts/lab118-services/wireguard.nix` | The `lab118.wireguard` options and the `wg-lab` tunnel. |
| `hosts/lab118-services/public-endpoints.nix` | nginx and ACME for `ntfy.` and `intake.`, plus the Node-RED intake listener. |
| `hosts/lab118-services/doppler-secrets.nix` | Which Doppler keys exist and which runtime files they turn into. |
| `hosts/lab118-services/disko.nix` | Disk layout (hybrid BIOS/UEFI GRUB). |
| `hosts/lab118-services/eval-test.nix` | Example values used by a flake check, not by the real host. |
| `modules/roles/notifications-stack.nix` | Alerta + PostgreSQL + Alerta web UI, ntfy, Apprise, Node-RED and the forwarder, as a reusable role. |
| `modules/roles/uptime-kuma.nix` | Kuma in Docker with a pinned image. |
| `modules/roles/doppler-secrets.nix`, `modules/roles/doppler-secrets/` | Secret sync with an encrypted last-known-good cache, and its tests. |
| `infra/terranix/lib/contabo-instance.nix` | The Contabo instance and its safety settings. |
| `infra/terranix/default.nix` | Every Terraform-managed host with its platform (`proxmox` or `contabo`). |
| `scripts/provisioning/provision-host.sh` | What `nix run .#plan/adopt/provision/install/switch/destroy` actually do. |
| `scripts/provisioning/plan-guard.jq` | Refuses dangerous Contabo plans. |
| `scripts/lab118/` | Health check, tunnel check, DNS probe, test alert. All read-only except the test alert. |
| `secrets/hosts/lab118-services.yaml` | Host-only SOPS file (bootstrap secrets). |

## How alerts flow

There are two halves. Something notices a problem and tells Alerta. Then a
small forwarder takes what Alerta knows and gets it onto the phone.

### Detection

Most alerts come from Uptime Kuma. Each monitor runs on its interval
(60 s for the lab checks) and records a heartbeat in Kuma's own SQLite history.

With Retries set to 2, the first two failures show as pending, and the third
in a row marks the monitor down. The first good check marks it up again.

Kuma only notifies on state changes. It does that through its built-in
Alerta notification, which POSTs to `http://notifications.host.internal:5000/alert`.
Inside the Kuma container, that name points at the Docker host.

What Kuma puts in the alert is fixed by Kuma's code:

| Alerta field | Value |
|---|---|
| `resource` | monitor name, e.g. `SVC / gitea` |
| `event` | monitor type, e.g. `http`, `ping`, `push` |
| `severity` | `critical` when down, `cleared` when up |
| `text` | `Service <type> is down.` / `... is up.` |
| `environment` | `Homelab` |
| `service`, `origin`, `tags` | `UptimeKuma`, `uptimekuma`, `uptimekuma` |
| `value` | always `Timeout` |

Kuma's actual error (connection refused, wrong keyword) doesn't make it into
the alert. The phone tells you what is down. Kuma tells you why.

The router heartbeat works the other way round. OPNsense calls
`https://intake.lab118.xyz/api/push/<token>` every minute over its normal
Internet connection. nginx passes `/api/push/` through to Kuma. If the pushes
stop, the `LAB / heartbeat: opnsense` push monitor goes down like any other monitor.

Node-RED and direct API calls are there for things that aren't Kuma checks:
scripts, webhooks, backup jobs. Nothing uses them yet.
- From the lab, POST to a Node-RED HTTP In node at
  `http://10.118.0.1:1880/intake/...`, and let the flow call Alerta. The
  `ALERTA_API_KEY` env var is already set inside Node-RED.
- Or POST straight to `http://10.118.0.1:5000/alert` with
  `Authorization: Key <api key>`.

Alerta identifies an alert by environment + resource + event.
- The same alert again with the same severity counts as a duplicate.
- A different severity updates the existing alert, and `cleared` closes it.
- Everything is kept in the `alerta` PostgreSQL database, so the web UI has
  the full history.
- `ALLOWED_ENVIRONMENTS` is `Production`, `Development`, `Homelab`; anything
  else is rejected.
- No Alerta plugins are enabled. Alerta itself never sends anything.

### Delivery

`alerta-apprise-forwarder` is a short Python service defined inline in the
notifications-stack role. Every 15 seconds it fetches open, acknowledged and
closed alerts. For each one it hashes the id, severity, status, text and any
custom title or body, and compares the result with
`/var/lib/alerta-apprise-forwarder/state.json`.
- A new hash means something changed, so it sends a notification and records the hash.
- Closed alerts that haven't changed in over an hour are recorded without sending.

That's what stops floods after a restart or a restore.

The message it builds:
- title: `attributes.notificationTitle`, or `[SEVERITY] resource: event`
- body: `attributes.notificationBody`, or the text, service, environment,
  group, origin, value, tags and id, one per line
- type: critical, major and security become `failure`; minor and warning
  become `warning`; normal, ok and cleared become `success`; anything else is `info`

It POSTs that to Apprise at `127.0.0.1:8000/notify/homelab-alerts`. If you want
nicer phone text from a Node-RED flow, set `notificationTitle` and
`notificationBody` in the alert's attributes.

Apprise holds one config key, `homelab-alerts`, rendered from Doppler's
`APPRISE_CONFIG`. Today that's a single line:
`ntfy://notifications.host.internal:8080/homelab-alerts?auth=token&token=...&xtags=alerts`.

Apprise turns the message into an ntfy publish: title to title, body to
message, the `alerts` tag, and an icon picked by type. Adding another
destination (email, Discord, anything Apprise supports) means adding a line to
`APPRISE_CONFIG` in Doppler.

ntfy checks the token (the `apprise` user may only write to
`homelab-alerts`) and keeps the message in its cache for about 12 hours.
Because `upstream-base-url` is `https://ntfy.sh`, it then sends ntfy.sh a poll
request containing only the message ID and a hash of the topic URL. Apple's
push service wakes the phone, and the ntfy app fetches the actual message from
`https://ntfy.lab118.xyz` with your login. The alert text never passes through
ntfy.sh.

The phone's server setting has to be exactly `https://ntfy.lab118.xyz`, because
the wake-up is keyed on that URL plus the topic.

### Where the data lives

| Data | Location |
|---|---|
| Monitors, check history (180 days by default), Kuma's copy of the Alerta API key | Docker volume `uptime-kuma` (`/app/data`) |
| Alerts and their history | PostgreSQL database `alerta` |
| What has already been notified | `/var/lib/alerta-apprise-forwarder/state.json` |
| Node-RED flows and credentials | `/opt/node-red/data` |
| Messages | ntfy cache in `/var/lib/ntfy-sh/` (about 12 h) |

None of this is backed up. Rebuilding the host loses it.

## Network

### Names and ports

| Name | Points at | Serves | Auth |
|---|---|---|---|
| `ntfy.lab118.xyz` | A record to the VPS | ntfy | ntfy users and tokens, deny-all by default |
| `intake.lab118.xyz` | A record to the VPS | `/api/push/` only, rate-limited; everything else 404 | the push token |
| `alerta.servicestack.xyz` | Pangolin (`*.servicestack.xyz` wildcard) | Alerta web UI, `127.0.0.1:5001` | Pangolin SSO, then Alerta login |
| `nodered.servicestack.xyz` | Pangolin | Node-RED editor, `127.0.0.1:1881` | Pangolin SSO |
| `kuma.servicestack.xyz` | Pangolin | Kuma UI, `127.0.0.1:3001` | Pangolin SSO, then Kuma login |

Both zones are at Porkbun. Direct names go in `lab118.xyz`
(`lab118.directDomain` in `configuration.nix`). Dashboards stay on
`servicestack.xyz` because that's the domain Pangolin serves.

| Port | Reachable from | What |
|---|---|---|
| TCP 22, 80, 443 | Internet | SSH, nginx |
| UDP 51820 | Internet | WireGuard (only the router has a key) |
| TCP 1880 | tunnel, Docker | nginx, forwards only `/intake/` to Node-RED |
| TCP 5000 | tunnel, Docker | Alerta API |
| TCP 8080 | tunnel, Docker | ntfy |
| TCP 3002 | tunnel | nginx, Kuma's status-page API only (GET under `/api/status-page/`, lab LAN only), for Homarr on the dashboard VM |
| 53 on `172.17.0.1` | Docker | resolver stub for containers |
| 1881, 3001, 5001, 8000, 9088 | localhost | Node-RED, Kuma, Alerta UI, Apprise, forwarder |

Assertions in `configuration.nix` fail the build if the public TCP set isn't
exactly 22/80/443, if a UDP port other than the WireGuard one opens, or if any
container port is published on something other than `127.0.0.1`.

The last one matters because Docker-published ports skip the NixOS firewall
entirely. The `lab118-services-exposure-guards` flake check proves the
assertions actually fire.

### Pangolin

Pangolin (1.11.1) runs on a Hetzner VPS. This host has its own Newt site,
`lab118-services`, run by the NixOS `services.newt` module with credentials
from Doppler. The dashboards don't depend on the lab's Newt.

Newt logs a warning that Pangolin's client features need 1.13 or newer. Those
features aren't used here.

To put another local service behind Pangolin: in Pangolin, add an HTTP
resource on site `lab118-services`, target `http://127.0.0.1:<port>`, with SSO
on. Nothing changes on the host as long as the service listens on localhost.

### The lab tunnel

The router dials out to the VPS, so the tunnel survives WAN IP changes and
needs nothing open on the lab side.

#### Cloud side

Set in `lab118.wireguard` in `configuration.nix`, implemented in `wireguard.nix`:
- interface `wg-lab`, address `10.118.0.1/30`, listening on UDP 51820
- private key from SOPS `wireguard/private-key`
- one peer, the router: public key `G5J3IbliB1PfRavKWU+Cl6q+SbEDS9gK7hGI9ZdeBwo=`,
  allowed `10.118.0.2/32` and `10.0.0.0/24`
- only `10.0.0.0/24` is routed into the tunnel; the default route and normal
  DNS stay on the VPS's own uplink
- `*.host.internal` names and the dashboard VM's two names
  (`dashboard.servicestack.xyz`, `beszel.servicestack.xyz`) are resolved by
  the lab's AdGuard Home at `10.118.0.2`; everything else uses public DNS.
  Publicly those two names go to Pangolin, whose SSO the Beszel agent and
  Kuma's checks can't pass.

#### Router side

OPNsense 24.7, configured by hand in the UI:

| What | Setting |
|---|---|
| WireGuard instance | `lab118-cloud`, listen 51821, tunnel `10.118.0.2/30` |
| Peer | `lab118-services`, endpoint `89.117.73.89:51820`, allowed `10.118.0.1/32`, keepalive 25 |
| Interface | `WG_LAB118`, assigned and enabled, no IP config |
| Rules on `WG_LAB118` | ICMP echo to `WG_LAB118 address`; ICMP echo to `10.0.0.1`; TCP/UDP 53 to `WG_LAB118 address`; TCP 443 to the dashboard VM (Kuma's checks and this host's Beszel agent). Everything else from the cloud is dropped. |
| WAN rule | ICMP echo from `89.117.73.89` only, so Kuma can ping the WAN address |

The phone and MacBook VPN is a separate WireGuard instance on `10.10.10.0/24`.
The WireGuard group tab has no rules. Keep it that way, or make sure any
group rule is limited to `10.10.10.0/24`, because group rules apply to every
instance, including this one.

#### Lab DNS

Why DNS goes to `10.118.0.2` and not `10.0.0.1`: AdGuard Home (port 53;
Unbound sits behind it on 5353) listens on all addresses. Asked at `10.0.0.1`
through the tunnel, it answers UDP from `10.118.0.2`, and the cloud drops the
reply. TCP worked, so lookups took about 20 seconds instead of failing
outright. `scripts/lab118/diagnose-lab-dns.sh` shows which address replies.

Lab DNS also has a wildcard: any `*.host.internal` name without its own
rewrite resolves to `10.0.0.81`, which is Nginx Proxy Manager. Its default
page returns 200.

#### Router heartbeat

These files live on OPNsense, outside its packages:

| Path | Contents |
|---|---|
| `/usr/local/sbin/lab118-heartbeat` | Reads the URL file and runs `curl -fsS` against it |
| `/usr/local/etc/lab118-heartbeat.url` | Root-only; holds the push URL with the token |
| `/usr/local/opnsense/service/conf/actions.d/actions_lab118.conf` | configd action `lab118 heartbeat` |

A cron job (System, Settings, Cron) runs "lab118 heartbeat to Uptime Kuma"
every minute. `configctl lab118 heartbeat` should print `OK`. `Error (22)`
means curl got an HTTP error, usually a bad URL.

When writing the URL file, don't paste the URL through zsh first; zsh escapes
`?`, `=` and `&` with backslashes.

### Lab monitors in Kuma

| Monitor | Check | Down means |
|---|---|---|
| `LAB / tunnel: router` | ping `10.118.0.2` | tunnel or router problem |
| `LAB / LAN: gateway via tunnel` | ping `10.0.0.1` | routing into the LAN is broken |
| `LAB / LAN: DNS via tunnel` | DNS A `pangolin-newt.host.internal` at `10.118.0.2` | lab DNS is down or unreachable |
| `LAB / WAN: public address` | ping `45.43.99.13` (static) | the lab's Internet connection |
| `LAB / heartbeat: opnsense` | push | the router stopped reaching the Internet, or its cron broke |

Read them together:
- Tunnel monitors down, heartbeat and WAN up: a WireGuard problem.
- Everything down: the lab is offline.
- Only the heartbeat down: look at the router's cron before assuming an outage.

Service monitors are named `SVC / <name>`. All of them alert individually.
Nothing is suppressed when the tunnel drops, so a tunnel outage also brings
down every service check behind it.

The dashboard VM's monitors (its health URL, the Beszel hub, and the push
monitors for its backups and the hub's heartbeat) are listed in
`docs/dashboard/REFERENCE.md`. Homarr reads Kuma through a status page over
the tunnel (port 3002), so whatever you want on the dashboard has to be on
that status page. The Hermes agents read a status page of their own, slug
`agents`, the same way: every monitor, with no clickable links and no tags,
so it shows states and response times but no URLs. They also read Alerta on
port 5000 with a key scoped to `read:alerts`, made with
`alertad key --username <admin> --scope read:alerts --text "agents read-only"`
(`docs/agents/REFERENCE.md`, "Lab state").

## Secrets

There are two layers on purpose.

SOPS (`secrets/hosts/lab118-services.yaml`) holds what the machine needs
before anything else works: the Doppler service token, the WireGuard key and
the root console password hash. It also holds the Beszel agent's token
(`beszel/agent-token`), there rather than in Doppler so turning the agent on
can't break the Doppler refresh. Only two keys can decrypt it: the host's own
age key (`/var/lib/sops-nix/key.txt`, with a copy in 1Password) and your
operator key. The broad operator key that decrypts `secrets/secrets.yaml` is
never put on this host.

Doppler holds the application secrets: personal workplace, project
`lab118-services`, config `prd`. Use the separate CLI config so it never
touches the work login:

```sh
DOPPLER_CONFIG_DIR=~/.doppler-personal doppler secrets --project lab118-services --config prd --only-names
```

The keys and the files they become are listed in
`hosts/lab118-services/doppler-secrets.nix`. Today those are the Alerta secret
key, admin user, admin password and API key, `APPRISE_CONFIG`,
`NTFY_AUTH_USERS`, `NTFY_AUTH_TOKENS`, `NEWT_ID` and `NEWT_SECRET`.

### How the sync works

`doppler-secrets.service` runs at boot. It decrypts
`/var/lib/doppler-secrets/cache.json.age` (encrypted to the host key and the
operator key) and writes the files into `/run/doppler-secrets/`. When a cache
exists it doesn't talk to Doppler at all, so the host restarts fine during a
Doppler outage. It only fetches from Doppler on the very first boot.

`doppler-secrets-refresh.timer` runs every 15 minutes. It fetches the config
and validates the whole set: every key present and non-empty, no line breaks
in values that go into env files, plus the regexes in `doppler-secrets.nix`.
Only then does it:
1. update the cache
2. swap changed files atomically
3. `try-restart` only the services listed for those files

If Doppler is down or the set is invalid, nothing changes and the unit fails
with exit code 2 (fetch failed) or 3 (invalid). Doppler's own `--fallback`
isn't used, because it saves whatever it fetched without checking it, and its
default passphrase is the token itself.

Three output formats exist:
- `raw`: the value as-is; multi-line is fine
- `systemd-env`: `NAME='value'` lines, for EnvironmentFile
- `docker-env`: `NAME=value` lines, for `--env-file`

Services only ever get file paths. No secret goes into the Nix store.

### Common changes

- Change a value: set it in Doppler. Within 15 minutes (or after
  `sudo systemctl start doppler-secrets-refresh` on the host) the file is
  updated and only its services restart. Watch it with
  `journalctl -u doppler-secrets-refresh`.
- Add a secret:
  1. Add the key in Doppler first.
  2. Add an output in `hosts/lab118-services/doppler-secrets.nix`, with its
     format, owner, mode and the services to restart.
  3. Point the service at `config.roles.dopplerSecrets.paths.<name>`.
  4. Deploy.

  If you deploy before the key exists in Doppler, the existing files stay as
  they are, `doppler-secrets` fails (the switch reports it), and the new file
  appears once the key is added and a refresh runs.
- Rotate the Doppler token:
  1. Create a new token and pipe it into SOPS with `--plain`.
  2. Deploy. The token change re-runs the refresh.
  3. Confirm the refresh logged success.
  4. Revoke the old token by slug (`doppler configs tokens` lists the slugs).

  The cache doesn't depend on the token.

  ```sh
  DOPPLER_CONFIG_DIR=~/.doppler-personal doppler configs tokens create <new-name> --project lab118-services --config prd --access read --plain | jq -Rs 'rtrimstr("\n")' | SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops set --value-stdin secrets/hosts/lab118-services.yaml '["doppler"]["service-token"]'
  ```

- Edit the SOPS file:
  `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/lab118-services.yaml`.
  On macOS, sops doesn't look in `~/.config/sops/age` unless you tell it to.

## Infrastructure and Terraform

The instance was bought in the Contabo panel and imported. Terraform keeps it
in state (R2 bucket `nix-terraform-state`, key
`hosts/lab118-services/terraform.tfstate`), shows its outputs and can rename
it. That's all Terraform is allowed to do here.

The reason is the provider (`contabo/contabo`, pinned at exactly `0.1.44`):
- Changing `image_id`, `ssh_keys`, `user_data`, `root_password` or
  `default_user` shows up as a harmless-looking in-place update but reinstalls
  the server, wiping the disk.
- `region`, `period`, `default_user` and `user_data` are never read back, so
  after an import they would always look changed.
- `destroy` cancels the contract.

So the module combines `prevent_destroy` with `ignore_changes` on all of those
fields, and `plan-guard.jq` refuses any plan that creates, deletes, replaces,
or changes anything other than `display_name`.

What the flake apps do for this host:

| Command | Effect |
|---|---|
| `nix run .#plan -- lab118-services` | Terraform plan, checked by the guard |
| `nix run .#provision -- lab118-services` | guarded plan, then apply after you type the host name. Never creates an instance. |
| `nix run .#adopt -- lab118-services <id>` | imports an instance bought in the panel |
| `nix run .#switch -- lab118-services` | `nixos-rebuild` on the host. No Terraform at all. |
| `nix run .#install -- lab118-services` | nixos-anywhere. Wipes the disk (details under Recovery). |
| `nix run .#destroy -- lab118-services` | refused |

Contabo API credentials live under `contabo.*` in `secrets/secrets.yaml`. Only
the Terraform commands need them.

## Making changes

Deploy with `nix run .#switch -- lab118-services`. It builds on the host and
connects to `facts.ipv4.address` unless `TARGET_HOST` is set.

Flakes only see files git knows about. Before evaluating or deploying, `git
add` (or `git add -N`) any new file.

Before deploying, these all run on the Mac:

```sh
nix build .#checks.aarch64-darwin.doppler-secrets
nix build .#checks.aarch64-darwin.provisioning
nix build .#checks.aarch64-darwin.lab118-services-eval
nix build .#checks.aarch64-darwin.lab118-services-exposure-guards
```

Then on the host:

```sh
ssh lab118-services 'sudo bash -s' < scripts/lab118/post-install-check.sh
ssh lab118-services 'sudo bash -s' < scripts/lab118/check-lab-tunnel.sh
```

### Patterns to follow

- Container images are pinned by tag and digest. To upgrade:
  1. Look up the new digest, e.g.
     `curl -s https://hub.docker.com/v2/repositories/louislam/uptime-kuma/tags/<tag> | jq -r .digest`.
  2. Change the pin in `configuration.nix`.
  3. Deploy.

  Do upgrades on their own, not mixed with other changes. Kuma and Node-RED
  migrate their data on major upgrades, and there are no backups, so copy the
  volume first.
- Containers publish on `127.0.0.1`. They reach host services through the
  `notifications.host.internal` alias (Docker's host-gateway), never `localhost`.
  The firewall opens 1880, 5000 and 8080 on `docker0` for that.
- Roles take paths and URLs as options. Nothing host-specific is
  hard-coded in `modules/roles/`. A second cloud host could reuse them with
  its own `facts.nix` and Doppler config.
- Facts are data, not logic. Provider details go in `facts.nix`, and an
  assertion stops the build if a required one is missing.
- No Home Manager on this host. `home-manager.users` is forced empty.
  Keep user tooling off an internet-facing box.
- PostgreSQL's major version follows `stateVersion`. Changing
  `stateVersion` is a database migration, not a cleanup.

### Adding a lab service to monitoring

No repo change is needed. Pick the Kuma monitor type first:

| Service | Kuma type | Router rule |
|---|---|---|
| Web app behind Nginx Proxy Manager, by `*.host.internal` name | HTTP(s) - Keyword | TCP to `10.0.0.81` ports 80 and 443, once for all such apps (a port alias `lab118_web_ports` is handy) |
| Web or API on its own host and port | HTTP(s) or Keyword | TCP to that host and port |
| Other TCP service | TCP Port | TCP to that host and port |
| Machine alive | Ping | ICMP echo to that host |
| Scheduled job | Push, with the URL host changed to `intake.lab118.xyz` | none |

Use Keyword checks for names behind the proxy. A wrong name still resolves to
the proxy and gets a 200, so a plain HTTP check can look healthy when it isn't.

1. Add the pass rule on `WG_LAB118`, with source `10.118.0.1`.
2. Test from the host, which uses the same tunnel and DNS as Kuma:
   `ssh lab118-services 'curl -sk -m 10 -o /dev/null -w "%{http_code}\n" https://<name>.host.internal/'`
3. Create the monitor:
   - name `SVC / <name>`
   - interval 60, retries 2, retry interval 60
   - Alerta notification on
   - "Ignore TLS/SSL errors" for self-signed certs
4. For anything important, break the keyword once and check that the phone
   gets the alert and the recovery.

### Other parts of the stack

- A local service through Pangolin: add the resource in Pangolin (see Pangolin above).
- A public endpoint without SSO: add an nginx virtual host in
  `public-endpoints.nix` with `enableACME`, and an A record in `lab118.xyz`.
  Only do this when the service has its own authentication.
- A notification destination: add a line to `APPRISE_CONFIG` in Doppler.

## Operations

### Upgrades

Upgrades are manual. There's no auto-upgrade on this host. The flow:
1. `nix flake update`
2. run the checks
3. switch
4. run the health check

### Recovery

- Bad config that still boots: open the Contabo VNC console, reboot,
  choose "NixOS - All configurations" in GRUB and pick the previous
  generation. Or log in as root with the console password and run
  `nixos-rebuild switch --rollback`.
- Won't boot: Contabo rescue system. Mount the ext4 root, which is
  partition 4 of `scsi-0QEMU_QEMU_HARDDISK_drive-scsi0`.
- Full reinstall:
  1. Reinstall Ubuntu from the panel.
  2. Add `~/.ssh/homelab_provision.pub` for root.
  3. Run:
     `HOST_AGE_KEY_FILE=<host key from 1Password> SSH_PRIVATE_KEY_PATH=~/.ssh/homelab_provision nix run .#install -- lab118-services`

  Reinstalling from the panel matters: the installer needs root over SSH,
  which the NixOS host doesn't allow.

  The first boot pulls secrets from Doppler. Kuma monitors, Alerta history
  and Node-RED flows are gone unless you copied them somewhere.
- Lost host age key: the operator key can still decrypt everything.
  1. Make a new key.
  2. Swap the recipient in `.sops.yaml`.
  3. Run `sops updatekeys secrets/hosts/lab118-services.yaml`.
  4. Put the new key at `/var/lib/sops-nix/key.txt` on the host.

  The old Doppler cache can't be decrypted with the new key, so the next boot
  rebuilds it from Doppler.

### Known limits

- No backups.
- Nothing outside watches this VPS itself.
- A rebuild during a Doppler outage needs the old cache file.
- sops-nix restarts services from the activation script, which NixOS deprecates in 26.11. After that, secret changes coming from SOPS (Doppler token, WireGuard key) may need a manual restart of the affected unit.

## Gotchas

- Acknowledging an alert in Alerta sends another phone notification, because
  the status is part of what the forwarder compares.
- Shelved alerts aren't fetched by the forwarder until they're unshelved.
- ntfy's user database is deleted and rebuilt from `NTFY_AUTH_USERS` and
  `NTFY_AUTH_TOKENS` on every start. Manage ntfy users in Doppler, not with the
  ntfy CLI.
- Changing the ntfy domain means re-adding the server and subscriptions on the
  phone.
- The Mac's 1Password SSH agent holds many keys. Without
  `IdentitiesOnly yes` in the `lab118-services` host entry, sshd can give up
  before reaching the right one.
- Proxy-backed names always resolve, even wrong ones (see the DNS wildcard
  above).

## Related

`hosts/notifications` and `hosts/uptime-kuma` are the old lab VMs this host
replaced. They're powered off and due for deletion. Don't use them as
examples; the roles in `modules/roles/` are the maintained version.
