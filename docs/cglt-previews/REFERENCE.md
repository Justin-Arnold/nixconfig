# cglt-previews

cglt-previews runs CGLT's pull-request previews. It's a NixOS VM on
proxmox4, deliberately not HA (see "Where it runs"). A pull request in the
monorepo can name instances in its body:

```
pr-preview: cureum-adelstg, satchel-cps
```

Each named instance (a tag) becomes a Docker Compose project with two
containers, the app and MySQL. Its database and files are a ZFS clone of a
nightly golden copy of that instance.

The monorepo's `pr-preview.yaml` and `preview-snapshots.yaml` drive all of
this from GitHub-hosted runners. Each job comes in over SSH, as
`preview-deploy` on port 2222, through a raw TCP resource on the Pangolin
VPS. It sends the monorepo's preview scripts along as a tar stream (see "How
GitHub Actions reaches the host"). Traefik routes `https://<tag>-pr<N>.preview.commongoodlt.dev` to each preview, using
the labels on the preview's containers. Dockhand, File Browser and Mailpit
are the ops tools.

It replaces the legacy `pr-previews` VM (`hosts/pr-previews`). That VM keeps
serving until the cutover.

## At a glance

| | |
|---|---|
| VM | Proxmox on proxmox4, 12 vCPU (CPU type `host`), 48 GB, 500 GB on `zfs-pool` (proxmox4's local ZFS), VM id 145, MAC `02:01:18:00:00:0b`, not HA, disk excluded from backups |
| Disk | 8 GB swap; 80 GB ext4 `/` (Docker); the rest is the ZFS pool `tank` (ashift 12, zstd, atime off, xattr sa) |
| Previews | `https://<tag>-pr<N>.preview.commongoodlt.dev`, public. The apps have their own login. |
| Ops tools | `dockhand.`, `files.` and `mail.preview.commongoodlt.dev`, each behind a login |
| Ingress | Pangolin VPS (wildcard TLS, hand-written route) → home site's Newt (`10.0.0.72`) → this VM, port 80 → Traefik |
| Deploys | GitHub-hosted runner → Pangolin VPS, raw TCP port 2222 → Newt → this VM, port 2222 → sshd, user `preview-deploy`, forced command `preview-ctl`. No runner on the host. |
| Login | `ssh justin@<vm-ip>` from the LAN or VPN, Mac Mini key only. Root has no SSH. `preview-deploy` has no login on port 22. |
| Console | Proxmox console; the root password is in SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/cglt-previews.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Upgrades | Nightly at 03:30 from `github:Justin-Arnold/nixconfig/master`. Reboots only when the kernel changed. |

### Where it runs

It runs on proxmox4 and isn't an HA resource. Justin chose that on
2026-11-09 for the fastest storage and CPU the cluster has:

- Its disk and cloud-init drive are on `zfs-pool`, proxmox4's local ZFS
  pool, which had 2.4 TB of 2.7 TB free when this host was made.
  proxmox4's `local-lvm` thin pool was already promised more than its
  816 GB, and a full thin pool pauses every VM on it.
- Its CPU type is `host`, so builds get everything proxmox4's two Xeon
  E5-2667 v4 (Broadwell, 32 threads) offer.

When proxmox4 is down, so are the previews, and deploy jobs fail at their
ssh step. The VM starts again with the node (`on_boot`).

If that proves unreliable, there are two ways out:

- **Make it HA**, like `automation`: disk and cloud-init drive on
  `nas-shared`, `cpuType = "x86-64-v2-AES"`, and an `ha` block.
  - proxmox1 (88 of 141 GB free on 2026-11-09, Westmere CPUs) is the only
    other node that can hold it.
  - The cluster has no HA group and uses the `basic` scheduler, so recovery
    would also need pinning to proxmox1. That's either an HA group
    `proxmox4:2,proxmox1:1` or the `static` scheduler.
  - Everything the guest writes, the ZFS pool and MySQL's commits included,
    would then go over NFS.
- **Move it to a cloud provider.**

There are no Proxmox backup jobs. The disk's `backup` flag is still off
(`diskBackup = false`), so a future job that covers every VM skips it. Its
contents can all be pulled again from the instances.

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/cglt-previews/configuration.nix` | The host: SOPS, ZFS, the datasets service, Docker, the firewall and egress rules, Beszel, autoUpgrade, and the exposure assertions. |
| `hosts/cglt-previews/facts.nix` | Shared addresses, names and paths. Part of the contract with the monorepo. |
| `hosts/cglt-previews/disko.nix` | The disk layout and the pool. |
| `hosts/cglt-previews/deploy.nix` | The SSH entry: `preview-deploy`, its sudo rule and work directory, sshd's port 2222 and Match blocks, and the guards on them. |
| `hosts/cglt-previews/preview-ctl.nix` | The forced command on port 2222. |
| `hosts/cglt-previews/preview-ctl-check.nix` | Runs `preview-ctl` against its contract with a stand-in `host.sh`. |
| `hosts/cglt-previews/ingress.nix` | Traefik, its middlewares and ops routes, and the `preview-edge` network. |
| `hosts/cglt-previews/ops.nix` | Dockhand, File Browser and Mailpit. |
| `hosts/cglt-previews/eval-test.nix` | Example values for the flake checks. The real host doesn't use it. |
| `infra/terranix/hosts/cglt-previews.nix` | The VM: its node, storage and CPU type, and why it isn't HA. |
| `secrets/hosts/cglt-previews.yaml` | The host's secrets. |

`.#checks.<system>.cglt-previews-eval` evaluates the host with an example
deploy key. `.#checks.<system>.cglt-previews-preview-ctl` runs `preview-ctl`
with good and bad requests. `.#checks.<system>.cglt-previews-exposure-guards`
breaks each rule below and fails unless evaluation refuses every case.

## The contract with the monorepo

The monorepo's `previews/` scripts and compose files depend on these. Change
both sides together.

| What | Value |
|---|---|
| Entry | `tar -czf - <files> \| ssh -p <port> -o HostKeyAlias=cglt-previews -o SendEnv='PREVIEW_*' preview-deploy@<host> <verb> [arg...]`. The tar must contain `previews/scripts/host.sh`. |
| Arguments | split on whitespace; each must match `^[A-Za-z0-9._:/=@+-]+$`; at least one |
| Exit status | `2` if `preview-ctl` refused the request, otherwise `host.sh`'s. `ssh` itself exits `255` when it can't connect or log in. |
| Environment | `PATH` (below), `HOME`, `USER`, `SSH_AUTH_SOCK` (with `ssh -A`) and every `PREVIEW_*` variable the client sends. Nothing else. |
| Job user | `preview-deploy` (uid and gid 2701), in group `docker` |
| ZFS | `sudo -n /run/current-system/sw/bin/zfs …` and `sudo -n /run/current-system/sw/bin/zpool …`. Nothing else goes through sudo, and `zfs` isn't on PATH. |
| Tools on PATH | bash, coreutils, docker 29 (with `compose` and `buildx`), git, jq, yq (yq-go), curl, rsync, openssh, gzip, zstd, util-linux (`flock`), sed, awk, grep, find, tar, and sudo from `/run/wrappers/bin`. Nothing else. |
| Work directory | `/var/lib/preview-deploy/work/job.XXXXXX`, on the root disk: the unpacked tar, and `host.sh`'s current directory. Removed when `host.sh` exits. |
| umask | `0022` |
| Golden copies | dataset `tank/previews/golden` at `/srv/previews/golden` |
| Live previews | dataset `tank/previews/live` at `/srv/previews/live` |
| Config | `/srv/previews/config`, a plain directory owned by `preview-deploy`, mode 0755. File Browser shows it. |
| Stacks | `/srv/previews/stacks`, a plain directory owned by `preview-deploy`, mode 0755. Dockhand sees it at the same path. |
| Edge network | the external Docker network `preview-edge` |
| Traefik | entrypoint `web`; a container is routed only with `traefik.enable=true`; middleware `preview-noindex@file` |
| Mail | SMTP `mailpit:1025` on `preview-edge`. No TLS. Any sender, any login or none. An `X-Tags` header tags the message. |
| Address pool | Compose networks get /24s from `172.20.0.0/14` |
| Logs | Docker's `local` driver. `docker logs` and Dockhand read it. |

A few things that are easy to get wrong:

- A dataset that `sudo zfs` creates or clones is owned by root. Files that
  File Browser or the PHP containers (uid 33) must write need their owner or
  ACLs set. `setfacl` works on files `preview-deploy` owns, because the pool
  has `acltype=posixacl`. A throwaway container can `chown` anything.
- A compose `ports:` entry publishes nothing reachable: DOCKER-USER drops
  every new inbound connection to a container. Traefik is the way in.
- Containers can't reach the LAN, the VPN, the tunnel or other private
  ranges. They can reach `10.0.0.1` (DNS) and the Internet. The host itself
  can additionally reach the Beszel hub. Uptime Kuma pushes go to
  `https://intake.lab118.xyz/api/push/…` over the Internet.
- The work directory is deleted when the job ends. Anything a preview needs
  later (compose files, config) must be copied to `/srv/previews/stacks` or
  `/srv/previews/config`. Build contexts can stay in it.
- The nightly upgrade at 03:30 may restart Docker, or reboot the VM when the
  kernel changed, and kill a job in progress. Schedule `preview-snapshots`
  well clear of 03:30–04:00.

## Dataset layout

```
tank                         mountpoint none; compression zstd, atime off, xattr sa, posixacl
└─ tank/previews             /srv/previews
   ├─ golden                 /srv/previews/golden     ← preview-snapshots: golden/<tag>{,/db,/files} @g-<UTC>
   ├─ live                   /srv/previews/live       ← pr-preview: live/pr-<N>-<tag>{,/db,/files}, clones of golden
   ├─ config/   (directory)  /srv/previews/config     ← pr-<N>-<tag>/config.instance.php, local-overrides.php
   └─ stacks/   (directory)  /srv/previews/stacks     ← pr-<N>-<tag>/compose.yaml, .env
```

`preview-datasets.service` creates `tank/previews`, `golden` and `live` when
they're missing, and creates the two directories. It runs after
`zfs-mount.service` and before Docker. It never touches anything below
`golden/` or `live/`.

`docker.service` requires both `zfs-mount.service` and
`preview-datasets.service`. If the pool doesn't import, Docker stays down.
That's deliberate: otherwise a preview's MySQL would start on an empty
directory.

The ARC is capped at 6 GB. A scrub runs monthly.

Never use `zfs destroy -R`: it also destroys the live clones of a golden
snapshot.

## How GitHub Actions reaches the host

The monorepo's workflows run on GitHub-hosted runners (`ubuntu-latest`).
Nothing on this host registers with GitHub. A job comes in over SSH:

```
GitHub-hosted runner ──ssh──▶ Pangolin VPS, raw TCP resource on port 2222
   ──▶ home site's Newt (10.0.0.72) ──tcp──▶ cglt-previews :2222 (sshd)
   ──▶ preview-ctl ──▶ bash previews/scripts/host.sh <verb> [arg...]
```

The monorepo's `previews/scripts/remote.sh` does the client side:

```sh
tar -czf - <files> | ssh -p "$PORT" -o HostKeyAlias=cglt-previews -o SendEnv='PREVIEW_*' \
  preview-deploy@"$HOST" <verb> [arg...]
```

### sshd on port 2222

sshd listens on 22 (admin) and 2222 (deploys). The firewall opens 2222 to
the Newt's address only. The settings for 2222 are `Match` blocks at the end
of `sshd_config`, written by `deploy.nix`:

- **Who.** `preview-deploy` and nobody else. Every other user gets
  `DenyUsers *`.
- **How.** Public key only (`AuthenticationMethods publickey`). Keys come
  from `/etc/ssh/authorized_keys.d/preview-deploy` only, so a key a job
  writes into `~/.ssh` isn't honoured.
- **What.** `ForceCommand preview-ctl`, whatever the client asked for.
- **Off:** TTYs, TCP and socket forwarding (`PermitOpen none`,
  `PermitListen none`), tunnels, X11 and `~/.ssh/rc`.
- **On:** agent forwarding. `preview-snapshots` reaches the source
  instances with the runner's forwarded agent. `AcceptEnv PREVIEW_*`.
- **Keepalive.** Every 30 s, giving up after 4 misses, so a cancelled job's
  session ends within about two minutes.
- **Logging.** `LogLevel VERBOSE`, so every login logs the key's
  fingerprint.

A second block, `Match LocalPort 22 User preview-deploy`, denies the deploy
user on the admin port. Each key in `cgltPreviews.deploy.authorizedKeys` is
also installed with `restrict,agent-forwarding` in front, so the key itself
carries the same limits.

Every connection on 2222 arrives from the Newt's address, because Newt opens
the connection to the VM itself. So there's no fail2ban or sshguard: one ban
would lock out every job. Don't turn on Pangolin's PROXY protocol for this
resource either, because sshd can't read it. Key-only login, the firewall
and Pangolin's single port are what front it. Pangolin applies no
authentication of its own to raw TCP resources.

`deploy.nix` asserts that:
- sshd listens on exactly 22 and 2222, and the Match blocks end the file;
- deploy keys carry no options of their own;
- `preview-deploy` has a real shell, because sshd runs the forced command
  through it;
- fail2ban and sshguard are off.

### preview-ctl

`preview-ctl` (`preview-ctl.nix`) is deliberately generic. Everything about
previews lives in the monorepo's `previews/scripts/host.sh`, which each job
sends, so this script rarely needs to change. For every connection it:

1. **Arguments.** Splits `SSH_ORIGINAL_COMMAND` on whitespace, without
   globbing. Each word must match `^[A-Za-z0-9._:/=@+-]+$`, and there must be
   at least one. A command with a newline in it is refused.
2. **Unpack.** Unpacks stdin, a gzip'd tar stream, into a fresh
   `/var/lib/preview-deploy/work/job.XXXXXX` (`--no-same-owner`). It checks
   that `previews/scripts/host.sh` is there.
3. **Run.** Runs `bash previews/scripts/host.sh <words>` from that
   directory:
   - in a clean environment (`env -i`): the fixed PATH from the contract
     table, `HOME`, `USER`, `SSH_AUTH_SOCK` and every `PREVIEW_*` variable;
   - with umask `0022`;
   - with stdout and stderr untouched, so they stream back into the Actions
     log and `::group::` and `::error::` lines still work.
4. **Clean up.** Removes the work directory and exits with `host.sh`'s
   status.

It exits `2`, with a `preview-ctl: …` line on stderr, if any of steps 1–2
fails.

**Trust.** `host.sh` comes from the pull request, so it's arbitrary code
running as `preview-deploy`. The docker group makes that root on this VM.
Whoever holds the deploy key can run anything here, and so can anyone whose
pull request the preview workflow runs. That's the same trust the
self-hosted runners had. `preview-ctl` checks the shape of the request and
nothing more. The network fence and the VM boundary are what contain a job.

**sudo and mounts.** sshd is a plain service. It runs in the host's mount
namespace and without `no_new_privs`, so:
- `sudo -n zfs` works from a session;
- a dataset a job clones or mounts is visible to Docker.

`deploy.nix` fails the build if sshd ever gets a mount-namespace or
seccomp option, or becomes socket-activated, for example after a nixpkgs
update.

**Leftovers.** Containers can leave root-owned files in a job directory,
which `preview-deploy` can't delete. The tmpfiles rule
`d /var/lib/preview-deploy/work 0750 preview-deploy preview-deploy 1d` lets
`systemd-tmpfiles-clean` (daily, as root) remove anything older than a day.

### The deploy key

1. On the Mac, make a key pair with no passphrase:
   ```sh
   ssh-keygen -t ed25519 -N '' -C cglt-previews-deploy -f ~/cglt-previews-deploy
   ```
2. Put the public half in `hosts/cglt-previews/configuration.nix`, as it is
   (`deploy.nix` adds the options):
   ```nix
   cgltPreviews.deploy.authorizedKeys = [ "ssh-ed25519 AAAA… cglt-previews-deploy" ];
   ```
3. Put the private half into the monorepo's Actions secret
   `PREVIEW_DEPLOY_KEY`:
   ```sh
   gh secret set PREVIEW_DEPLOY_KEY --repo commongoodlt/CGLT-Monorepo < ~/cglt-previews-deploy
   ```
   Expected output: `✓ Set Actions secret PREVIEW_DEPLOY_KEY for commongoodlt/CGLT-Monorepo`.
4. Keep the private key on the Mac until "Verify" passes. Then store it in
   1Password and delete both files from the Mac.

Until step 2 is done, nothing can deploy, and every build prints a warning
that the deploy key list is empty.

To rotate: make a new pair, add its public half next to the old one, switch,
replace the secret, then remove the old public half and switch again.

## Ingress

```
browser ──https──▶ Pangolin VPS 5.161.94.68 (Traefik, *.preview.commongoodlt.dev wildcard cert)
        ──▶ home site's Newt (pangolin-newt VM, 10.0.0.72) ──http :80──▶ cglt-previews Traefik
            ├─ <tag>-pr<N>.preview…  ▶ container on preview-edge (Docker labels)
            ├─ dockhand.preview…     ▶ 127.0.0.1:3000  (basic auth "ops-auth", then Dockhand)
            ├─ files.preview…        ▶ 127.0.0.1:8081  (File Browser login)
            └─ mail.preview…         ▶ 127.0.0.1:8025  (Mailpit login)
```

Port 80 only accepts the Newt. Traefik trusts `X-Forwarded-*` from the Newt
alone, so the apps see `https` and don't redirect to http. Every response
carries `X-Robots-Tag: noindex, nofollow` (`preview-noindex`).

There is no Traefik API, dashboard, ping or metrics endpoint. There is no
other entrypoint and no other provider. The assertions in `ingress.nix` keep
it that way.

### The Pangolin VPS route

The VPS route that sends `*.preview.commongoodlt.dev` to the lab, and the
wildcard certificate behind it, were written by hand on the VPS. A copy is in
`docs/cglt-previews/vps/`, captured on 2026-11-09 (Pangolin 1.11.1, gerbil
1.2.2, Traefik v3.5, installed in `/opt/pangolin`).

It works like this:

- The router is `preview-wildcard`, in
  `/opt/pangolin/config/traefik/dynamic_config.yml`. Its rule is
  ``HostRegexp(`^.+\.preview\.commongoodlt\.dev$`)``, it serves the wildcard
  certificate (resolver `letsencrypt`, Porkbun DNS challenge), and its
  service is `preview-tunnel`, at `http://100.89.128.4:53526`.
- **The VPS can't reach a LAN address.** `100.89.128.4` is the home site's
  Newt inside Pangolin's WireGuard network. `53526` is the port Newt listens
  on for one target of one Pangolin resource. Newt forwards whatever arrives
  there to that target's LAN address.
- The hand-written route borrows the tunnel port of the dashboard resource
  **`pr-preview-test`** (`preview-proxy.commongoodlt.dev`, resource id 5).
  That resource's target decides where every preview request goes. It was
  the legacy `pr-previews` VM.
- So that resource must stay even after the legacy previews are gone. At
  cutover only its target changes, to this VM on port 80 (see "Repointing
  at cutover" below).

To capture what's there now, run these from the Mac, in this repo's root:

```sh
mkdir -p docs/cglt-previews/vps

# 1. What runs there, and where Traefik's config is mounted from.
ssh root@5.161.94.68 'docker ps --format "{{.Names}}\t{{.Image}}"'
ssh root@5.161.94.68 'docker inspect traefik --format "{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}"'

# 2. Every file under those sources that mentions the preview domain.
#    (Traefik's config is mounted from /opt/pangolin/config/traefik.)
ssh root@5.161.94.68 'grep -rIln "preview" /opt/pangolin/config/traefik | grep -v acme.json'

# 3. Copy each file step 2 listed, plus the static config, with secret
#    values masked.
for f in /opt/pangolin/config/traefik/traefik_config.yml /opt/pangolin/config/traefik/dynamic_config.yml; do
  ssh root@5.161.94.68 "cat $f" \
    | sed -E 's/((token|key|secret|password|email)[A-Za-z_]*["]?[[:space:]]*[:=][[:space:]]*).*/\1<redacted>/I' \
    > "docs/cglt-previews/vps/$(basename "$f")"
done

# 4. Which certificates Traefik holds (names only, no keys), and the names of
#    the DNS provider's variables (no values).
ssh root@5.161.94.68 'jq -r ".[] | .Certificates[]? | .domain | [.main] + (.sans // []) | join(\" \")" /opt/pangolin/config/letsencrypt/acme.json'
ssh root@5.161.94.68 'docker inspect traefik --format "{{range .Config.Env}}{{println .}}{{end}}"' | sed 's/=.*/=<redacted>/'

# 5. For the deploy port: Pangolin's install directory (the source mounted
#    on /app/config, minus /config), whether raw resources are on, which
#    ports gerbil publishes, and whether anything already listens on 2222.
ssh root@5.161.94.68 'docker inspect pangolin --format "{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}"'
ssh root@5.161.94.68 'grep -n -A6 "^flags:" /opt/pangolin/config/config.yml; docker port gerbil; ss -ltn "sport = :2222"'
```

What to expect:

- **Step 2** lists the dynamic file that has the `*.preview` router.
- **Step 3** writes that file and `traefik_config.yml` into
  `docs/cglt-previews/vps/`. Look in them for:
  - the router rule, for example ``HostRegexp(`{sub:[a-z0-9-]+}.preview.commongoodlt.dev`)``;
  - its `tls.domains` (`*.preview.commongoodlt.dev`) and `certResolver`;
  - the service URL. This is the target to repoint later.
  - the resolver's `dnsChallenge.provider`.
- **Step 4** prints the certificate list, which should include
  `*.preview.commongoodlt.dev`, and variable names such as
  `PORKBUN_API_KEY=<redacted>`.
- **Step 1** also shows the versions: the `fosrl/pangolin:<version>` and
  `fosrl/gerbil:<version>` image tags. Raw TCP resources need Pangolin
  1.0.0-beta.9 or later. Any 1.x release qualifies.
- **Step 5** prints:
  - the mount `/opt/pangolin/config -> /app/config`;
  - the `flags:` block, possibly with `allow_raw_resources: true` already;
  - gerbil's published ports (51820/udp, 21820/udp, 443, 80);
  - an empty `ss` table if port 2222 is free.

Read every captured file before you commit it. Make sure nothing secret got
past the masking.

#### Repointing at cutover

Don't put a LAN address in `dynamic_config.yml`: the VPS can't reach it.

1. In the Pangolin dashboard, open **Resources** → `pr-preview-test` →
   **Targets**. Change the target's **IP / Hostname** to this VM's address
   and its **Port** to `80`. Leave the method `http` and the site as the
   home site. Keep its health check off: it's off today, and an unhealthy
   target takes every preview offline. Save.
2. See which tunnel port Pangolin gave the target now:
   ```sh
   ssh root@5.161.94.68 'docker exec traefik wget -qO- http://pangolin:3001/api/v1/traefik-config' \
     | jq -r '.http.services["5-pr-preview-test-service"].loadBalancer.servers[].url'
   ```
   Expected: one URL, such as `http://100.89.128.4:53526`.
3. If that URL isn't `http://100.89.128.4:53526`, put it in the
   `preview-tunnel` service's `url:` in
   `/opt/pangolin/config/traefik/dynamic_config.yml`. Traefik's file provider
   reloads without a restart.
4. Copy the file into `docs/cglt-previews/vps/` again.

Check from anywhere: `curl -sI https://mail.preview.commongoodlt.dev | head -1`
prints `HTTP/2 401`.

### The Pangolin raw TCP resource (deploys)

GitHub-hosted runners reach port 2222 on this VM through a raw TCP resource
on the VPS: VPS port 2222 → the home site's Newt → `<vm-ip>:2222`. Like the
web route, it lives only on the VPS. The steps come from Pangolin's docs:

- [Raw TCP & UDP resources](https://docs.pangolin.net/manage/resources/public/raw-resources)
- [Config file](https://docs.pangolin.net/self-host/advanced/config-file)
- [Docker Compose](https://docs.pangolin.net/self-host/manual/docker-compose)
- [Targets](https://docs.pangolin.net/manage/resources/public/targets)

Versions:
- **Pangolin:** 1.0.0-beta.9 or later. Step 5 of the capture above shows it.
- **Newt:** 1.0.0-beta.5 or later. The home site's Newt is the nixpkgs
  `fosrl-newt` on `pangolin-newt`, 1.20.0 in this flake.
- **Names:** Pangolin 1.23 renamed Newt to "Pangolin Site" in places. The
  dashboard may also call the resource type "Raw TCP/UDP resource" (older)
  or just "TCP" (newer).

Run these on the VPS (`ssh root@5.161.94.68`), in Pangolin's install
directory `/opt/pangolin`:

1. **Turn raw resources on.** This was already on when the VPS was
   captured on 2026-11-09. In `config/config.yml`:
   ```yaml
   flags:
     allow_raw_resources: true
   ```
   Set it explicitly, even though the docs' table says it defaults to true:
   Pangolin's code treats a missing key as off, and the TCP type then never
   appears in the dashboard. Leave `traefik.allow_raw_resources` alone if
   it's there; it's a different setting.
2. **Add the entrypoint.** In `config/traefik/traefik_config.yml`, under
   `entryPoints:` next to `web` and `websecure`:
   ```yaml
     tcp-2222:
       address: ":2222/tcp"
   ```
   The name must be `tcp-2222`: Pangolin routes a TCP resource on port N to
   the entrypoint `tcp-N`.
3. **Publish the port.** In `docker-compose.yml`, add it to the `gerbil`
   service's `ports:`. Traefik shares gerbil's network, so the port goes
   there:
   ```yaml
       ports:
         - 2222:2222
   ```
4. **Open the firewall.** The VPS runs ufw, which denies by default. On
   2026-11-09 it allowed 22, 80, 443, 51820/udp and 21820/udp. Run
   `ufw allow 2222/tcp`. If the provider's cloud firewall is attached to the
   server, allow TCP 2222 there too. On Hetzner that's Cloud Console →
   Firewalls.
5. **Restart the stack:**
   ```sh
   docker compose down && docker compose up -d && docker compose ps
   ```
   Expected output: `pangolin`, `gerbil` and `traefik` all `Up`, with
   pangolin `(healthy)`.
6. **Create the resource.** In the Pangolin dashboard:
   1. Go to **Resources** (newer: **Public Resources**) → **Add Resource**.
   2. Set **Type** to **TCP** ("Raw TCP/UDP resource" on older versions).
      The type can't be changed later.
   3. Set **Name** to `cglt-previews-deploy` and **Port** to `2222`. This is
      the port on the VPS.
   4. Create it. The page then shows "Configuration Snippets" for the
      Traefik entrypoint and the gerbil port, which should match steps 2–3.
   5. Under **Targets** → **Add Target**, set **Site** to the home site,
      **IP / Hostname** to `<vm-ip>` and **Port** to `2222`. Save.
   6. Leave **Enable Proxy Protocol** off. sshd can't parse a PROXY header,
      so every connection would fail.
   7. **Turn the target's health check off**, then Save Settings again.
      Pangolin 1.11 turns it on for new targets, and its check is an HTTP
      `GET /`. sshd fails that, the target is marked `unhealthy`, and
      Pangolin leaves the whole resource out of Traefik's config, so `.tcp`
      in the check below is `null`. To see the state, run on the VPS:
      `sqlite3 -readonly /opt/pangolin/config/db/db.sqlite "select targetId, hcEnabled, hcHealth from targetHealthCheck"`.
7. **Check from the Mac.** Run `nc -vz -w 5 5.161.94.68 2222`. Expected:
   `succeeded`. Through to sshd, `ssh-keyscan -t ed25519 -p 2222 5.161.94.68`
   should print the same key as `ssh-keyscan -t ed25519 <vm-ip>` from the
   LAN.

How it works:
- **Source address.** Newt opens the TCP connection to the VM itself, so
  sshd sees every deploy as coming from `10.0.0.72`. That's why the firewall
  allows 2222 from the Newt only, and why there's no fail2ban.
- **Timeouts.** Neither Traefik nor Newt puts an idle timeout on an
  established TCP connection. Pangolin's docs don't cover it, so this comes
  from their source. sshd's 30 s keepalive and the client's
  `ServerAliveInterval=30` keep long builds alive anyway.
- **No authentication.** Pangolin's own login and rules don't apply to raw
  resources. The deploy key is the only gate.

## Ops tools

| Tool | URL | Login | Notes |
|---|---|---|---|
| Dockhand 1.0.57 | `dockhand.preview.commongoodlt.dev` | Traefik basic auth (`traefik/ops-users`), then Dockhand's own | Starts with its own login off. There's no setting to force it on, hence the basic-auth gate. Turn it on under Settings → Authentication. In the free edition every account is an admin, and Dockhand has the Docker socket, so give accounts to developers only. |
| File Browser 2.63.23 | `files.preview.commongoodlt.dev` | `filebrowser/admin-username` and the password behind `filebrowser/admin-password-hash` | Runs as uid 33 on `/srv/previews/config`, with the command runner off. The credentials are read only when its database is first created. |
| Mailpit 1.33.1 | `mail.preview.commongoodlt.dev` | `mailpit/ui-auth` | Keeps the last 5000 messages in `/var/lib/mailpit`. |

Every image is pinned by digest. To move one, look up the new tag's digest
and change both the tag and the digest in `ops.nix`:

```sh
curl -s https://hub.docker.com/v2/repositories/<repo>/tags/<tag> | jq -r .digest
```

File Browser's repository was archived on 2026-09-01, so there will be no
more releases or security fixes. 2.63.23 is its last release. It only sits
behind its own login on config files, but it should be replaced.

## The network fence

Whoever holds the deploy key is root on this VM, and so is any pull request
the preview workflow runs. The firewall therefore keeps the VM, and every
container on it, out of the rest of the lab.

| Direction | Rule |
|---|---|
| In | TCP 22 from `10.0.0.0/24` and `10.10.10.0/24`; TCP 80 and 2222 from `10.0.0.72` (the Newt); nothing else. `allowedTCPPorts` is forced empty. |
| Host out (`OUTPUT` → `preview-egress`) | Allowed: loopback, replies, `10.0.0.1`, and `10.0.0.151:443` (the Beszel hub). Refused: everything else in `10.0.0.0/8`, `100.64.0.0/10`, `169.254.0.0/16`, `192.168.0.0/16` and `fc00::/7`. |
| Containers (`DOCKER-USER`) | Allowed: replies, and `10.0.0.1`. Dropped: new connections from outside `172.16.0.0/12`. Refused: the same private ranges as the host. |

Refusals are logged with the prefix `preview-egress` (at most 10 a minute):

```sh
journalctl -k -g preview-egress
```

This is a fence against mistakes and against a compromised app container.
A malicious job can undo it, since it's root. An OPNsense rule that drops
traffic from this VM's address into the LAN would hold even then.

## Secrets

`secrets/hosts/cglt-previews.yaml` is encrypted to the host's own age key
and to the operator key, nothing else. The host key is
`~/.config/sops/age/hosts/cglt-previews.txt` on the Mac; keep a copy in
1Password. Edit the file with:

```sh
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/cglt-previews.yaml
```

Every value starts as `pending`. `provision` refuses to run while any value
is still `pending`.

| Key | What | Make it with |
|---|---|---|
| `root/console-password-hash` | the root password for the Proxmox console | `nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt` |
| `beszel/agent-token` | the Beszel hub's universal token | the hub's UI |
| `traefik/ops-users` | htpasswd lines (bcrypt) for the gate in front of Dockhand | `nix shell nixpkgs#apacheHttpd -c htpasswd -nB <user>`, one line per person |
| `dockhand/encryption-key` | encrypts what Dockhand stores. Never change it. | `openssl rand -base64 32` |
| `filebrowser/admin-username` | File Browser's first admin | e.g. `admin` |
| `filebrowser/admin-password-hash` | that admin's bcrypt hash | `nix shell nixpkgs#apacheHttpd -c htpasswd -nB admin \| cut -d: -f2` |
| `mailpit/ui-auth` | htpasswd lines (bcrypt) for Mailpit's UI | `nix shell nixpkgs#apacheHttpd -c htpasswd -nB <user>`, one line per person |

The deploy key isn't in SOPS. Its public half is in `configuration.nix`
and its private half is a GitHub secret (see "The deploy key").

## First install

Run each step from the repo root, `~/Code/personal/nixconfig`.

1. Fill in the secrets (table above). Then check that none are left:
   ```sh
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops -d secrets/hosts/cglt-previews.yaml | grep -c pending
   ```
   Expected output: `0`.
2. Make the deploy key and set `cgltPreviews.deploy.authorizedKeys` (see
   "The deploy key", steps 1–2).
3. In OPNsense, reserve an address for MAC `02:01:18:00:00:0b`.
4. Check that everything evaluates:
   ```sh
   scripts/flake-check.sh eval cglt-previews
   ```
   Expected output: `ok    cglt-previews`, then `all passed`.
5. Look at the plan:
   ```sh
   nix run .#plan -- cglt-previews
   ```
   Expected output: one resource to create, then
   `Plan: 1 to add, 0 to change, 0 to destroy.`
   - `proxmox_virtual_environment_vm.cglt-previews will be created`, with:
     - `node_name = "proxmox4"` and `vm_id = 145`;
     - `cpu { cores = 12, type = "host" }` and
       `memory { dedicated = 49152 }`;
     - `disk { datastore_id = "zfs-pool", interface = "scsi0", size = 500, backup = false }`;
     - `initialization { datastore_id = "zfs-pool" … }`;
     - `mac_address = "02:01:18:00:00:0b"`.
   - No `proxmox_haresource`.
6. Create the VM and install it:
   ```sh
   HOST_AGE_KEY_FILE=~/.config/sops/age/hosts/cglt-previews.txt SSH_PRIVATE_KEY_PATH=~/.ssh/homelab_provision nix run .#provision -- cglt-previews
   ```
   Expected output: the same plan, then
   `Apply complete! Resources: 1 added, 0 changed, 0 destroyed.`, then
   `Discovered DHCP IP for cglt-previews: 10.0.0.x`, nixos-anywhere's
   output, and finally
   `Saved hardware configuration to …/hosts/cglt-previews/hardware-configuration.nix`.
7. Give the Mac an SSH entry for the VM, like the other lab hosts have.
   `~/.ssh/config` sets `IdentitiesOnly yes` for every host, so without an
   entry naming the Mac Mini key, `switch` fails with
   `justin@10.0.0.x: Permission denied (publickey)`.
   ```sh
   printf '\nHost cglt-previews 10.0.0.156\n  HostName 10.0.0.156\n  User justin\n  IdentityFile ~/.ssh/ssh-client-macmini.pub\n  IdentitiesOnly yes\n' >> ~/.ssh/config
   ssh cglt-previews true && echo ok
   ```
   Expected output: `ok`, after approving the key in 1Password.
8. Track the generated hardware configuration, then switch:
   ```sh
   git add hosts/cglt-previews/hardware-configuration.nix
   nix run .#switch -- cglt-previews
   ```
   Expected output: the build, then `activating the configuration…` with no
   failed units.
9. Pin the host key in the monorepo. Port 2222 only accepts the Newt, so
   scan port 22 from the LAN; both ports present the same host key:
   ```sh
   ssh-keyscan -t ed25519 <vm-ip> 2>/dev/null | sed 's/^[^ ]*/cglt-previews/'
   ssh justin@<vm-ip> ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```
   Expected output: one line `cglt-previews ssh-ed25519 AAAA…`, then the
   host's fingerprint. Check that the line's fingerprint matches it
   (`ssh-keygen -lf <(echo '<the line>')`). Then put the line in the
   monorepo's `previews/known_hosts`.
10. Create the Pangolin raw TCP resource (see "The Pangolin raw TCP
   resource").
11. Give the monorepo the key and the address:
    ```sh
    gh secret set PREVIEW_DEPLOY_KEY --repo commongoodlt/CGLT-Monorepo < ~/cglt-previews-deploy
    gh variable set PREVIEW_SSH_HOST --repo commongoodlt/CGLT-Monorepo --body 5.161.94.68
    gh variable set PREVIEW_SSH_PORT --repo commongoodlt/CGLT-Monorepo --body 2222
    ```
    Expected output: `✓ Set Actions secret PREVIEW_DEPLOY_KEY …`, then
    `✓ Created variable PREVIEW_SSH_HOST …` and `… PREVIEW_SSH_PORT …`.
    A DNS name that points at the VPS works as the host too.

Then check it with the steps in "Verify". Last, add the Kuma and Beszel
entries (see "Outside the repo").

## Verify

Run these on the VM (`ssh justin@<vm-ip>`) unless a step says otherwise.

```sh
sudo zpool status tank
# state: ONLINE … errors: No known data errors

zfs list -r -o name,mountpoint tank
# tank                  none
# tank/previews         /srv/previews
# tank/previews/golden  /srv/previews/golden
# tank/previews/live    /srv/previews/live

ls -ld /srv/previews/config /srv/previews/stacks
# drwxr-xr-x … preview-deploy preview-deploy …   (both)

docker compose version      # Docker Compose version v2.…
docker buildx version       # github.com/docker/buildx v0.…

systemctl is-active sshd traefik docker-dockhand docker-filebrowser docker-mailpit
# active (five times)
```

**SSH entry.** On the VM, check sshd's effective settings for each user and
port. OpenSSH 10.6 prints the names in CamelCase, hence `grep -i`.

```sh
sudo sshd -T -C user=preview-deploy,host=newt,addr=10.0.0.72,lport=2222 \
  | grep -iE '^(denyusers|authenticationmethods|forcecommand|permittty|allowtcpforwarding|allowagentforwarding|acceptenv) '
# AuthenticationMethods publickey, ForceCommand /nix/store/…-preview-ctl/bin/preview-ctl,
# PermitTTY no, AllowTcpForwarding no, AllowAgentForwarding yes, AcceptEnv PREVIEW_*,
# and no DenyUsers line
sudo sshd -T -C user=justin,host=newt,addr=10.0.0.72,lport=2222 | grep -i '^denyusers'
# DenyUsers *
sudo sshd -T -C user=preview-deploy,host=lan,addr=10.0.0.50,lport=22 | grep -i '^denyusers'
# DenyUsers *
```

From the Mac, on the LAN:

```sh
nc -vz -w 5 <vm-ip> 2222
# times out: 2222 accepts the Newt only
ssh -i ~/cglt-previews-deploy -o IdentitiesOnly=yes preview-deploy@<vm-ip> true
# preview-deploy@<vm-ip>: Permission denied (publickey).
```

Through Pangolin, from a monorepo checkout (`cd ~/Code/cglt/monorepo`),
with the host key pinned (First install, step 9):

```sh
o=(-p 2222 -o IdentitiesOnly=yes -o HostKeyAlias=cglt-previews -o UserKnownHostsFile=previews/known_hosts -o StrictHostKeyChecking=yes)
ssh "${o[@]}" -i ~/cglt-previews-deploy preview-deploy@5.161.94.68 list < /dev/null; echo "exit $?"
# gzip: stdin: unexpected end of file … preview-ctl: stdin must be a gzip'd tar stream
# exit 2
ssh "${o[@]}" justin@5.161.94.68 true
# justin@5.161.94.68: Permission denied (publickey).
tar -czf - previews | ssh "${o[@]}" -i ~/cglt-previews-deploy preview-deploy@5.161.94.68 capacity
# host.sh's capacity table
```

Then, on the VM:

```sh
journalctl -u sshd -n 30 | grep -E 'preview-deploy|DenyUsers'
# Accepted publickey for preview-deploy from 10.0.0.72 port … ssh2: ED25519 SHA256:…
# User justin from 10.0.0.72 not allowed because listed in DenyUsers
ls -A /var/lib/preview-deploy/work
# (nothing)
```

**Routing.**

```sh
docker run -d --name whoami --network preview-edge \
  -l traefik.enable=true \
  -l 'traefik.http.routers.whoami.rule=Host(`x-pr0.preview.commongoodlt.dev`)' \
  -l traefik.http.routers.whoami.entrypoints=web \
  -l traefik.http.routers.whoami.middlewares=preview-noindex@file \
  traefik/whoami:v1.12.0@sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44
curl -si -H 'Host: x-pr0.preview.commongoodlt.dev' http://127.0.0.1/ | head -20
# HTTP/1.1 200 OK, X-Robots-Tag: noindex, nofollow, and whoami's "Hostname: …" lines
```

From the Newt, the same request should give the same answer:
`ssh pangolin-newt curl -s -H 'Host: x-pr0.preview.commongoodlt.dev' http://<vm-ip>/`.

From the Mac it should time out, because port 80 only accepts the Newt:
`curl -m 5 http://<vm-ip>/`.

Remove the test container afterwards with `docker rm -f whoami`.

**Logins.**

```sh
for h in dockhand mail; do curl -s -o /dev/null -w "$h %{http_code}\n" -H "Host: $h.preview.commongoodlt.dev" http://127.0.0.1/; done
# dockhand 401
# mail 401
curl -s -o /dev/null -w "files %{http_code}\n" -H 'Host: files.preview.commongoodlt.dev' http://127.0.0.1/api/resources/
# files 401
```

**Fence.**

```sh
docker run --rm --network preview-edge curlimages/curl:8.23.0 -sS -m 5 http://10.0.0.20/
# curl: (7) Failed to connect to 10.0.0.20 port 80 …: Could not connect to server  (or "No route to host")
docker run --rm --network preview-edge curlimages/curl:8.23.0 -sS -m 10 -o /dev/null -w '%{http_code}\n' https://github.com/
# 200
sudo -u preview-deploy curl -sS -m 5 http://10.0.0.20/
# the same refusal
journalctl -k -g preview-egress -n 5
# preview-egress(container): … DST=10.0.0.20 … and preview-egress: … DST=10.0.0.20 …
```

**Reboot ordering.** Run `sudo systemctl reboot`. Once the VM is back:

```sh
systemd-analyze critical-chain docker.service
# docker.service … └─preview-datasets.service … └─zfs-mount.service …
findmnt -no SOURCE,FSTYPE /srv/previews
# tank/previews zfs
docker ps --format '{{.Names}}'
# dockhand, filebrowser, mailpit
```

## Operations

```sh
journalctl -u sshd -g preview-deploy -n 50               # deploy logins, with key fingerprints
ls -la /var/lib/preview-deploy/work                       # job directories; empty unless a job is running
journalctl -u traefik -n 100                              # access log and routing errors
docker ps --filter label=cglt.preview.pr                  # every preview container
zfs list -r -o name,used,refer,origin tank/previews/live  # what each preview holds
sudo zpool list tank                                      # pool free space
```

Rebuilding the VM means running
`nix run .#destroy -- cglt-previews`, then `provision` again with
`HOST_AGE_KEY_FILE` and `SSH_PRIVATE_KEY_PATH=~/.ssh/homelab_provision`. Golden copies are pulled again by `preview-snapshots`.
Previews come back the next time their pull request is pushed to or
redeployed.

## Outside the repo

- **OPNsense:** a DHCP reservation for `02:01:18:00:00:0b`. Optionally, a
  rule that drops this VM's traffic into the LAN, as a fence that holds even
  against root on the VM.
- **Pangolin VPS:**
  - the `*.preview` route and wildcard certificate. They ride the tunnel port
    of the dashboard resource `pr-preview-test`, so keep that resource (see
    "The Pangolin VPS route");
  - the raw TCP resource on port 2222, with its flag, entrypoint, gerbil
    port and firewall opening (see "The Pangolin raw TCP resource").
- **GitHub** (`commongoodlt/CGLT-Monorepo`): the secret
  `PREVIEW_DEPLOY_KEY`, the variables `PREVIEW_SSH_HOST` and
  `PREVIEW_SSH_PORT`, and the host key in `previews/known_hosts`.
- **Uptime Kuma:**
  - a monitor for `https://mail.preview.commongoodlt.dev` expecting 401,
    which shows ingress is up;
  - a TCP port monitor on `5.161.94.68:2222`, which shows the deploy path is
    up through Pangolin and the Newt.
- **Beszel:** add the system on the hub with the universal token.

## Known limits

- Deploy jobs are root on this VM through the docker group, and `host.sh`
  comes from the pull request. The fence above and the VM boundary are what
  contain them.
- sshd sees every deploy as coming from the Newt (`10.0.0.72`). Logs tell
  jobs apart by key and time, not address, and nothing rate-limits per
  client.
- It isn't HA. When proxmox4 is down, so are the previews and deploys (see
  "Where it runs").
- The nightly upgrade can restart Docker, or reboot the VM, in the middle of
  a job.
- File Browser is archived upstream (see "Ops tools").
- Dockhand's free edition makes every account an admin.
- IPv6: only ULA (`fc00::/7`) is refused. Docker networks have no IPv6.

## Related

- The monorepo's `previews/README.md`: tags, reset and limits, for
  developers.
- `docs/automation/REFERENCE.md`: the same host pattern (own age key,
  exposure guards).
