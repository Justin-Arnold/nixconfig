### Command to switch flake

```
nix run nix-darwin -- switch --flake ~/Code/personal/nixconfig
```
With a certain host

```
nix run nix-darwin -- switch --flake ~/Code/personal/nixconfig#macmini
```

### Provision a new Proxmox VM from a personal machine

Render the Terraform plan for a host:

```sh
nix run .#plan -- <host>
```

Create the VM in Proxmox and bootstrap it with `nixos-anywhere`:

```sh
nix run .#provision -- <host>
```

Destroy the managed VM:

```sh
nix run .#destroy -- <host>
```

Currently managed hosts: `dockhand`, `notifications`, `uptime-kuma`, `pr-previews`.

The provisioning flow expects:

- Proxmox credentials sourced from the provisioning-runner Home Manager role
- a bootstrap SSH key at `~/.ssh/id_ed25519`
- an age key at `~/.config/sops/age/keys.txt` if you want that copied during install
- a shared SSH-reachable bootstrap template in Proxmox for the target VM to clone
- a working DHCP service on the target network; provisioning will discover the lease automatically and use that IP for `nixos-anywhere`

Dockhand also expects SOPS secret values at `dockhand/env` (`ENCRYPTION_KEY=...`) and `dockhand/hawser.env` (`TOKEN=...`).

The notifications host expects SOPS secret values at:

- `notifications/alerta/secret-key`: Flask/Alerta secret key text
- `notifications/alerta/admin-user`: Alerta admin login, such as `justin`
- `notifications/alerta/admin-password`: Alerta admin password
- `notifications/alerta/api-key`: fixed Alerta ingest API key for producers using `Authorization: Key ...`
- `notifications/apprise/config`: Apprise text config for the stateful `homelab-alerts` key, one Apprise URL per line
- `notifications/ntfy/auth-users`: ntfy comma-separated `auth-users` entries
- `notifications/ntfy/auth-tokens`: ntfy comma-separated `auth-tokens` entries

Notifications host service URLs:

- Alerta web UI: `http://notifications.host.internal:5001`
- Alerta API: `http://notifications.host.internal:5000`
- Node-RED UI: `http://notifications.host.internal:1880`
- ntfy web UI/API: `http://notifications.host.internal:8080`
- Apprise API: `http://127.0.0.1:8000` on the notifications host only

Node-RED is intentionally UI-managed. Nix provisions the service and persistent
data directory, but notification intake and transformation flows should be built
and maintained in the Node-RED editor.
