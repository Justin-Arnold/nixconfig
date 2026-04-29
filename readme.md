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
nix run .#plan -- uptime-kuma
```

Create the VM in Proxmox and bootstrap it with `nixos-anywhere`:

```sh
nix run .#provision -- uptime-kuma
```

Destroy the managed VM:

```sh
nix run .#destroy -- uptime-kuma
```

The provisioning flow expects:

- Proxmox credentials sourced from the provisioning-runner Home Manager role
- a bootstrap SSH key at `~/.ssh/id_ed25519`
- an age key at `~/.config/sops/age/keys.txt` if you want that copied during install
- a shared SSH-reachable bootstrap template in Proxmox for the target VM to clone
- a working DHCP service on the target network; provisioning will discover the lease automatically and use that IP for `nixos-anywhere`
