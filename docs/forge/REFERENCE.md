# forge

forge is the lab's own Git forge: Forgejo on a NixOS VM on the Proxmox
cluster, reachable from the LAN and the road-warrior VPN and nowhere else.
Its first job is the vault's history. The agents host keeps the vault in git
(`hosts/agents/notes.nix`), one commit per agent change and one per batch of
changes from Obsidian Sync, and pushes that history here within seconds of
each commit, so you can read who changed what, and when, in a browser. Later
it can hold your private projects, and maybe the agents' repos (see
[agents-repos-plan.md](agents-repos-plan.md); none of that is built).

It's also the first name on `lab118.xyz` for a lab service, the start of
moving off `servicestack.xyz`.

The vault's history is plaintext and includes journals and finances. The
forge's copy is private to you, can't be rewritten, and can't be reached from
outside the LAN and the VPN. No agent has an account here.

## At a glance

| | |
|---|---|
| VM | Proxmox, 2 vCPU (`x86-64-v2-AES`), 4 GB, 40 GB on `nas-shared`, MAC `02:01:18:00:00:0c`, address `10.0.0.157`, HA resource |
| Web | `https://git.lab118.xyz` (Forgejo 15 LTS from nixpkgs, SQLite) |
| Git | `ssh://forgejo@git.lab118.xyz/<owner>/<repo>.git`, or HTTPS with a token |
| Reachable from | the LAN (`10.0.0.0/24`) except Pangolin's Newt (`10.0.0.72`), and the VPN (`10.10.10.0/24`) |
| Login | `ssh justin@10.0.0.157`, key only (the Mac Mini key). Root has no SSH. |
| Console | Proxmox console, root password from SOPS (`root/console-password-hash`) |
| Secrets | `secrets/hosts/forge.yaml`, host-scoped age key at `/var/lib/sops-nix/key.txt` |
| Backups | Nightly at 03:15, NFS share on the NAS, age-encrypted, Kuma push monitor |

## Where things live in the repo

| Path | What it is |
|---|---|
| `hosts/forge/configuration.nix` | The host: users, SOPS, the firewall, the Beszel agent, and the exposure assertions. |
| `hosts/forge/facts.nix` | forge's address, name and SSH host key, shared with the agents host. |
| `hosts/forge/forgejo.nix` | Forgejo's settings, its sandbox, and `forge-admin`. |
| `hosts/forge/endpoints.nix` | ACME (Porkbun DNS-01) and nginx. |
| `hosts/forge/backup.nix` | The NFS mount and what gets backed up. |
| `infra/terranix/hosts/forge.nix` | The VM, its storage, CPU type and HA resource. |
| `hosts/agents/notes.nix`, `hosts/agents/notes/notes-mirror.sh` | `notes-mirror`, which pushes the vault's history here. |

## How it's reached

AdGuard rewrites `git.lab118.xyz` to `10.0.0.157` for the LAN and the VPN.
There's no public DNS record and no Pangolin resource. nginx serves the name
with a Let's Encrypt certificate from Porkbun DNS-01, since nothing on the
Internet can reach the VM. The name does show up in Certificate
Transparency logs, as every Let's Encrypt name does; its address doesn't.

The firewall (nftables) drops everything from Pangolin's Newt first, then
accepts TCP 22, 80 and 443 from the LAN and the VPN, and nothing else. nginx
repeats it: its one location denies the Newt, allows the two ranges and
denies the rest. So Pangolin stays out even if one of the two is changed, and
the assertions in `configuration.nix` and `endpoints.nix` fail the build if
either one is.

Forgejo listens on a Unix socket, and `forgejo.service` can't open a
connection beyond loopback (`IPAddressDeny=any`). Mirrors, migrations,
webhooks to the outside and update checks have nowhere to go, so nothing in
Forgejo can copy a repository off this host. Git over SSH goes through the
system's OpenSSH as `forgejo`, whose `authorized_keys` Forgejo writes with
every key pinned to `forgejo serv`. sshd lets in `justin` and `forgejo` and
no one else.

Unknown names and the bare IP get no certificate and no content.

### DNS and router settings this depends on

These live outside the repo:
- An AdGuard rewrite for `git.lab118.xyz` to `10.0.0.157` (AdGuard Home on
  OPNsense, Filters, DNS rewrites).
- An OPNsense DHCP reservation of `10.0.0.157` for `02:01:18:00:00:0c`. The
  MAC is fixed in Terraform, so the address follows the VM through migration
  and HA recovery. `hosts/forge/facts.nix` has the same address, and the
  agents host pushes to it by address.
- Porkbun API access for `lab118.xyz`, in two places: the domain's own API
  access setting, and the lab's shared API key, which Porkbun limits to the
  domains listed on it. `lab118.xyz` was added to that key on 2026-11-24, next
  to `servicestack.xyz`, so every host that holds it (agents, automation,
  dashboard, inference, openclaw and forge) can change `lab118.xyz`'s
  records too. lab118-services gets its certificates over HTTP.
- No Pangolin resource, and no `WG_LAB118` rule: lab118-services has no
  reason to reach this host.

LAN clients only take the direct path when AdGuard answers them. A second,
public DNS server, or the browser's own secure DNS, finds no record for the
name and fails.

## Forgejo

What `hosts/forge/forgejo.nix` sets, and why:

| Setting | Why |
|---|---|
| `DISABLE_REGISTRATION`, `REQUIRE_SIGNIN_VIEW` | Nobody signs up; accounts are made with `forge-admin`. Nothing shows to a visitor who isn't signed in. |
| `GLOBAL_TWO_FACTOR_REQUIREMENT = all` | Every account needs a second factor, TOTP or a security key (WebAuthn), before it can use the site. |
| `FORCE_PRIVATE` | Every repository is private, whatever its owner picks. |
| `mirror`, `actions`, `packages`, LFS, federation off | No mirrors in either direction, no CI. |
| `DISABLE_MIGRATIONS` | Importing from another forge would need the network the service doesn't have. Push a repository instead. |
| `oauth2.ENABLED = false`, OpenID off | Forgejo signs nobody in to other apps, and nobody signs in here through another provider. |
| `OFFLINE_MODE`, the update checker off | No Gravatar, no CDN, no calls home. |

It runs as `forgejo` with a fixed UID and GID (3000), so restored files keep
their owner. `sudo forge-admin <args>` runs `forgejo admin` as that user
with its config (`sudo forge-admin user list`).

## The vault's history

`notes-mirror` on the agents host runs `git push --mirror` of
`/var/lib/notes/vault` to `justin/vault` here:
- A path unit on the vault's `.git/refs/heads` starts it whenever a branch
  moves, so a commit is here within seconds. An hourly timer starts it too,
  in case a start was missed.
- After a push it reads the refs again and pushes again if a commit landed
  meanwhile.
- While forge is down it fails and tries again after 30 seconds, backing off
  to every 30 minutes.
- Each run writes `/var/lib/notes-mirror/status.json` on the agents host:
  when it last pushed, and git's first error line from the last failure.
  agent-watch raises `MirrorStale` in Alerta, which reaches the phone, once
  there's been no good push for two and a half hours (Monitoring).
- It runs as `notes` in a group of its own, `notes-mirror`, that no user is
  in. That group can read the deploy key, and an nftables rule lets it open
  TCP 22 to `10.0.0.157` and nothing else. Its unit's own filter allows only
  that address. The other notes units run as `notes` too but get neither,
  and keep the network they had: none, loopback, or loopback and the
  Internet.
- It can't write to the vault, and runs no hooks from it.
- It pins forge's host key (`sshHostKey` in `hosts/forge/facts.nix`). Until
  that's set, the mirror is off and the agents host warns at build time.

The repository is yours and private, with no collaborators. Its branch,
`main`, is protected: only the deploy key may push to it, never a force
push, and it can't be deleted. So a rewritten history on the agents host fails the
push instead of replacing what's here. The deploy key belongs to this one
repository and can write nowhere else.

What "nobody can change it" doesn't cover: you're the site admin, so your
account can lift the protection or delete the repository. Keep that account
behind its second factor, and don't push to the repository yourself; the
mirror would remove any branch the vault doesn't have.

Where the history comes from: notes.py commits each agent change at once,
under the agent's name, and commits what arrived through Sync every 10
seconds, as "Obsidian Sync". A change from your devices shows up here after
Sync brings it to the agents host, about 10 seconds, and the push.

## First install

Run each step from the repo root. The by-hand parts are the age key and
secrets, the router and NAS settings, your Forgejo account, the vault's
repository, and the deploy key.

1. Make the host's age key, and keep a copy in 1Password:
   ```sh
   mkdir -p ~/.config/sops/age/hosts
   nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/hosts/forge.txt
   ```
   Expected output: `Public key: age1…`.
2. Add the recipient to `.sops.yaml`, above the generic rule:
   ```yaml
   # Same arrangement for forge.
   forge_recipients: &forge_recipients
     - age1… # forge host
     - age1ljfvx33psxcat4wwjpq6u26f5fv9jzntg8z266mhykpxh78upalqxfflz3 # operator
   ```
   and, in `creation_rules`, before `^secrets/.*\.ya?ml$`:
   ```yaml
     - path_regex: ^secrets/hosts/forge\.ya?ml$
       key_groups:
         - age: *forge_recipients
   ```
3. Create the secrets file with every key in "Secrets" below, then track it:
   ```sh
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/forge.yaml
   git add .sops.yaml secrets/hosts/forge.yaml
   ```
4. Outside the repo:
   - In OPNsense, reserve `10.0.0.157` for `02:01:18:00:00:0c`.
   - In AdGuard, rewrite `git.lab118.xyz` to `10.0.0.157`.
   - In Porkbun, turn on API access for `lab118.xyz`, and add `lab118.xyz`
     to the shared API key's domains. Without the second, the order fails
     with a 403: the key "is restricted to specific domains".
   - On TrueNAS, export `/mnt/Main/backups/forge-backups` over NFS to
     `10.0.0.157` only, root mapped to root.
   - In Kuma, make a push monitor `JOB / forge backup` with a 26 hour
     heartbeat; its URL is `kuma/backup-push-url`.
5. Check that it evaluates, without the "doesn't exist yet" warning:
   ```sh
   scripts/flake-check.sh eval forge
   ```
   Expected output: `ok    forge`, then `all passed`.
6. Look at the plan: one VM on `proxmox7` with the MAC above, its disk and
   cloud-init drive on `nas-shared`, and one `proxmox_haresource`.
   ```sh
   nix run .#plan -- forge
   ```
7. Create the VM and install it:
   ```sh
   HOST_AGE_KEY_FILE=~/.config/sops/age/hosts/forge.txt SSH_PRIVATE_KEY_PATH=~/.ssh/homelab_provision nix run .#provision -- forge
   ```
   It ends with `Saved hardware configuration to …/hosts/forge/hardware-configuration.nix`.
   `provision` only installs while that file doesn't exist; once it does,
   `provision` just switches. To install over a VM again, use `install`.
   The bootstrap key has to exist when the VM is created, or the VM gets a
   placeholder nobody can log in with. Without `SSH_PRIVATE_KEY_PATH` the
   script uses `~/.ssh/id_ed25519`.
8. Switch once, so the generated hardware configuration is the one running:
   ```sh
   git add hosts/forge/hardware-configuration.nix
   nix run .#switch -- forge
   ```
9. Check the certificate and the firewall from the desktop:
   ```sh
   curl -sI https://git.lab118.xyz/ | head -1
   ```
   Expected output: `HTTP/2 303` or `HTTP/2 200` (the sign-in page). From
   the VPN it should answer the same; the Newt gets nothing.
10. Make your account, then sign in at `https://git.lab118.xyz` and set up
    the second factor when Forgejo asks (TOTP, or a security key or passkey
    under Settings, Security). Keep the recovery code in 1Password.
    ```sh
    ssh justin@10.0.0.157 sudo forge-admin user create --admin --username justin \
      --email hello@justin-arnold.com --random-password --must-change-password
    ```
    It prints the password once; change it at the first sign-in.
11. Make the vault's repository, empty: New repository, owner `justin`, name
    `vault`, no README, no license. In its settings:
    - Units: turn off issues, pull requests, wiki, releases, projects and
      the rest; only the code view is needed.
    - Branches, add a protection rule for `main`, the vault's only branch:
      push restricted to a whitelist with no users and deploy keys with
      write access allowed, force pushes off. A protected branch can't be
      deleted.
12. Make the deploy key on the desktop, give the public half to the
    repository with write access (Settings, Deploy keys, title
    `agents notes-mirror`), and put the private half in the agents host's
    secrets as `notes/forge-deploy-key`:
    ```sh
    ssh-keygen -t ed25519 -N '' -C notes-mirror@agents -f ~/notes-mirror
    cat ~/notes-mirror.pub
    SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/agents.yaml
    shred -u ~/notes-mirror ~/notes-mirror.pub
    ```
    In sops, paste the private key as a block scalar
    (`forge-deploy-key: |` under `notes:`), every line indented, ending
    with a newline.
13. Pin forge's host key. Read it on the VM, and compare its fingerprint with
    the one your first `ssh` to the VM showed:
    ```sh
    ssh justin@10.0.0.157 cat /etc/ssh/ssh_host_ed25519_key.pub
    ssh justin@10.0.0.157 ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
    ```
    Put the whole line in `sshHostKey` in `hosts/forge/facts.nix`. Commit,
    then switch the agents host:
    ```sh
    scripts/flake-check.sh eval agents
    nix run .#switch -- agents
    ```
    Expected output: no "notes-mirror is off" warning.
14. Start the first push and read it:
    ```sh
    ssh agents sudo systemctl start notes-mirror
    ssh agents sudo journalctl -u notes-mirror -n 5 --no-pager
    ```
    Expected output: `notes-mirror: forge has <commit>`. The history is then
    at `https://git.lab118.xyz/justin/vault/commits/branch/main`.
15. Check the protection holds from your own account: clone the repository,
    make a commit, and push it. Forgejo refuses it.

## Secrets

`secrets/hosts/forge.yaml` is encrypted to the host's own age key and the
operator key, nothing else. The host key is
`~/.config/sops/age/hosts/forge.txt`; keep a copy in 1Password. On macOS,
sops doesn't look in `~/.config/sops/age`, so edit it with
`SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops secrets/hosts/forge.yaml`.

| Key | What |
|---|---|
| `root/console-password-hash` | `nix shell nixpkgs#mkpasswd -c mkpasswd -m yescrypt` |
| `porkbun/api-key`, `porkbun/secret-api-key` | for DNS-01; the same pair as the other hosts, with `lab118.xyz` on its list of domains in Porkbun |
| `beszel/agent-token` | the Beszel hub's universal token |
| `kuma/backup-push-url` | the `JOB / forge backup` push monitor's URL |

On the agents host, in `secrets/hosts/agents.yaml`:

| Key | What |
|---|---|
| `notes/forge-deploy-key` | the private half of the vault repository's deploy key (First install, step 12). Readable by root and the `notes-mirror` group only. |

Forgejo makes its own `SECRET_KEY`, `INTERNAL_TOKEN` and JWT secret on first
start, in `/var/lib/forgejo/custom/conf`. They aren't in SOPS; the backup
carries them (below).

The host key is installed by `nix run .#install` from `HOST_AGE_KEY_FILE`
(`hostAgeKey = true` in `infra/terranix/default.nix`), the same way as on
dashboard. Install refuses the operator key, a key that isn't in
`.sops.yaml`, a missing secrets file, a file it can't decrypt with the host
key, and any value still set to `pending`. Unlike the other hosts, forge
evaluates without its secrets file, with a warning, so `scripts/flake-check.sh`
passes before you've made it.

## Backups

`roles.sqliteBackup` runs at 03:15 (plus up to 10 minutes):
- It snapshots `/var/lib/forgejo/data/forgejo.db` with SQLite's online
  backup, as `forgejo`, and checks its integrity.
- It copies the repositories (`/var/lib/forgejo/repositories`), Forgejo's
  generated secrets (`custom/conf`), and the avatars and attachments.
- It encrypts the archive to the host and operator keys and writes it to
  `/mnt/forge-backups` (NFS, mounted on demand, `soft`).
- It reads the archive back, keeps 30 days (never fewer than 7 archives),
  and reports up or down to `kuma/backup-push-url`.

`SECRET_KEY` travels in the archive because it encrypts the second factors
in the database: a restore onto a new VM brings back the key with the data
it opens. The archive is as private as the repositories in it, the vault's
history among them, and only the host and operator keys open it.

```sh
sudo systemctl start sqlite-backup     # a backup now
sudo sqlite-backup list                # archives, newest first
sudo journalctl -u sqlite-backup
```

The export is `10.0.0.20:/mnt/Main/backups/forge-backups` on TrueNAS
(`forge.backup.nfsDevice`). The share only accepts the VM's address and maps
root to root, so the job can write and prune its archives.

The repositories are copied as files, while Forgejo keeps running. A push
that lands during the copy can leave that night's copy of that repository
inconsistent. The vault's history is the least exposed to this: the agents
host has its own copy, in its own backups, and the next mirror push restores
it here.

The NAS holds both the VM's disk and the backups; see dashboard's "Backups"
for what that covers and what it doesn't.

### Restoring a backup

```sh
sudo sqlite-backup list
sudo sqlite-backup restore /mnt/forge-backups/forge-<time>.tar.zst.age
```

It stops Forgejo, puts the database, repositories and secrets back (keeping
what it replaced as `*.pre-restore-<time>`), and starts it again. Forgejo
writes `authorized_keys` again on every start, so SSH keys work after a
restore onto a new VM too. Afterwards, `git fsck` in a repository you care
about is a quick check:
`sudo -u forgejo git -C /var/lib/forgejo/repositories/justin/vault.git fsck`.

## Monitoring

| What | Where | Down means |
|---|---|---|
| Beszel agent | the hub on dashboard | the VM is down or overloaded |
| `JOB / forge backup` | Kuma push, 26 h heartbeat | the nightly backup failed or didn't run |
| `MirrorStale` (`agents/notes-mirror`) | Alerta, from agent-watch on the agents host | the agents host hasn't pushed the vault's history here for two and a half hours, with git's reason |

There's no Kuma HTTP check: Kuma runs on lab118-services, which can't reach
this host. Forge being down shows as `MirrorStale` too, once no push has
got through for two and a half hours, so a forge reboot doesn't raise it.

## Operations

### Rebuilding the VM

`nix run .#install -- forge` with `HOST_AGE_KEY_FILE` and
`SSH_PRIVATE_KEY_PATH=~/.ssh/homelab_provision` set recreates the VM if it's
gone and installs it. `provision` wouldn't install here, since the hardware
configuration is committed by then. Then restore the newest backup. The new VM has a new SSH host
key, so the mirror stops with a host key error until you pin the new one
(First install, step 13). That's on purpose: the agents host won't push the
vault to a machine it doesn't know.

### Upgrading

Forgejo comes from nixpkgs (`forgejo-lts`), so it moves with
`nix flake update`. Run `sudo systemctl start sqlite-backup` first; its
migrations only go forward.

## Known limits

- Your admin account can change or delete the vault's repository; nothing
  else can.
- The forge is a second place the vault's plaintext history lives, next to
  the agents host. Anyone who gets root on forge, or a shell as `forgejo`,
  can read it.
- The nightly copy of a repository isn't atomic (Backups).

## Related

- `hosts/agents/notes.nix`: the vault on the agents host, and `notes-mirror`.
- [agents-repos-plan.md](agents-repos-plan.md): what moving the agents'
  repos here would take.
- `docs/dashboard/REFERENCE.md`: the same VM layout, HA and NAS backups.
