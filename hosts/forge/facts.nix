# What forge and the hosts that reach it share: its address, its name and
# its SSH host key. The agents host pushes the vault's history here
# (hosts/agents/notes.nix), and pins this host key to do it.
{
  # An OPNsense DHCP reservation for the VM's MAC (02:01:18:00:00:0c in
  # infra/terranix/hosts/forge.nix), so the address follows the VM through
  # migration and HA recovery.
  address = "10.0.0.157";

  # The name AdGuard rewrites to `address` for the LAN and the VPN. There's
  # no public record and no Pangolin resource for it.
  domain = "git.lab118.xyz";

  # Git over SSH goes through the system's OpenSSH as this user, on port 22.
  sshUser = "forgejo";
  sshPort = 22;

  # forge's ed25519 host key (/etc/ssh/ssh_host_ed25519_key.pub), the whole
  # line. Until it's here, the agents host doesn't push the vault: fill it
  # in after the first install (docs/forge/REFERENCE.md, "First install").
  sshHostKey = null;

  # Who may open a connection to forge at all: the LAN and the road-warrior
  # VPN.
  allowedSources = [ "10.0.0.0/24" "10.10.10.0/24" ];

  # The home site's Newt (the pangolin-newt VM). It's inside the LAN range,
  # and Pangolin's traffic arrives from it, so it's shut out by name.
  pangolinNewt = "10.0.0.72";
}
