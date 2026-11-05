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

Currently managed hosts: `dockhand`, `notifications`, `uptime-kuma`, `pr-previews`, `dashboard`, `agents`, `workbench`, `openclaw`, `inference` (Proxmox) and `lab118-services` (Contabo).

### Cloud host lab118-services

`lab118-services` is a Contabo VPS that runs the notification stack and Uptime
Kuma outside the lab. Its flow is different from the Proxmox one: the server is
bought in the Contabo panel and imported with `nix run .#adopt`, `switch` and
`install` never run Terraform, and `destroy` is refused. See
[docs/lab118-services/REFERENCE.md](docs/lab118-services/REFERENCE.md).

### Monitoring dashboard

`dashboard` is a Proxmox VM running Homarr and the Beszel hub, set up for
Proxmox HA (shared storage, a common CPU model, an HA resource). It installs
with its own age key instead of the operator key, so `install` and the first
`provision` need `HOST_AGE_KEY_FILE`. Provisioning refuses any plan that would
delete or replace a VM, and finds a VM on whichever node HA moved it to. See
[docs/dashboard/REFERENCE.md](docs/dashboard/REFERENCE.md).

### Agent orchestration

`agents` is a Proxmox VM running Paperclip on PostgreSQL, the task and
approval layer for the lab's AI agents. It's built and installed like
`dashboard` (HA, its own age key). See
[docs/agents/REFERENCE.md](docs/agents/REFERENCE.md).

`workbench` is where those agents' work runs: their terminal and file tools
act there over ssh, in git worktrees, with rootless Podman. It has its own age
key but no HA, since nothing on it needs keeping. See
[docs/workbench/REFERENCE.md](docs/workbench/REFERENCE.md).

`openclaw` is the chat front door to them: an OpenClaw gateway whose only
tool is Paperclip, so asking it for something files an issue for the
coordinator. It's built and installed like `agents` (HA, its own age key).
See [docs/openclaw/REFERENCE.md](docs/openclaw/REFERENCE.md).

`inference` is the GPU host: the RTX 3090 passed through on proxmox2, serving
one model as `local` through llama-server, behind nginx with a key per client,
to the agents and Home Assistant's voice assistant, plus Home Assistant's
Whisper and Piper. It has its own age key and no HA, since it's tied to the
node with the card. See [docs/inference/REFERENCE.md](docs/inference/REFERENCE.md).

The provisioning flow expects:

- Proxmox credentials sourced from the provisioning-runner Home Manager role
- a bootstrap SSH key at `~/.ssh/id_ed25519`
- an age key at `~/.config/sops/age/keys.txt` if you want that copied during install (hosts with `hostAgeKey = true` get `HOST_AGE_KEY_FILE` instead and never this one)
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

Node-RED receives `ALERTA_API_KEY` from the same
`notifications/alerta/api-key` SOPS secret. Function nodes can read it with
`env.get("ALERTA_API_KEY")`.

Notifications host service URLs:

- Alerta web UI: `http://notifications.host.internal:5001`
- Alerta API: `http://notifications.host.internal:5000`
- Node-RED UI: `http://notifications.host.internal:1880`
- ntfy web UI/API: `http://10.0.0.192:8080`
- Apprise API: `http://127.0.0.1:8000` on the notifications host only

For ntfy iOS push, set the iOS app's Default Server to exactly
`http://10.0.0.192:8080`. The server uses ntfy.sh as its upstream push relay,
but notification fetches still go back to this private URL.

Node-RED is intentionally UI-managed. Nix provisions the service and persistent
data directory, but notification intake and transformation flows should be built
and maintained in the Node-RED editor.
