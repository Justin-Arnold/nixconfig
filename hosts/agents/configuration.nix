# agents: the lab's agent orchestration host, a NixOS VM on the Proxmox
# cluster. It runs Paperclip (task state, approvals, budgets, the activity
# log) on PostgreSQL, and the Hermes agents (agents.nix). It holds their model
# logins but never runs code the agents generate; that happens on
# workbench. Like dashboard it can move between nodes: disk and cloud-init
# drive on nas-shared, an HA resource, a CPU model every node has, nothing
# passed through (infra/terranix/hosts/agents.nix). See docs/agents/REFERENCE.md.
{ config, lib, inputs, sops-nix, ... }:
let
  macMiniKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com";

  fw = config.networking.firewall;
  publicTcpPorts = lib.sort lib.lessThan (lib.unique fw.allowedTCPPorts);
  publicUdpPorts = lib.unique fw.allowedUDPPorts;
  interfaceRules = lib.filterAttrs
    (_: i: i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ] || i.allowedTCPPortRanges != [ ] || i.allowedUDPPortRanges != [ ])
    fw.interfaces;
  # The NixOS firewall always trusts the loopback interface.
  trustedInterfaces = lib.subtractLists [ "lo" ] fw.trustedInterfaces;

  containers = config.virtualisation.oci-containers.containers;
  # Every container shares the host's network and binds loopback itself, so
  # nothing is published and nothing can skip the firewall.
  loopbackOnly = c: lib.elem "--network=host" c.extraOptions && (c.environment.HOST or "") == "127.0.0.1" && c.ports == [ ];
  exposedContainers = lib.attrNames (lib.filterAttrs (_: c: !(loopbackOnly c)) containers);
  socketMounts = lib.attrNames (lib.filterAttrs
    (_: c: lib.any (v: lib.hasInfix "docker.sock" v || lib.hasInfix "podman.sock" v || lib.hasInfix "/run/podman" v) c.volumes)
    containers);
  paperclipEnv = containers.paperclip.environment;

  egress = config.roles.agentEgress;
  unfilteredAgents = lib.filter (name: !(egress.enable && lib.elem "hermes-${name}" egress.users))
    (lib.attrNames config.roles.hermesAgents.instances);
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./endpoints.nix
      ./backup.nix
      ./agent-watch.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ./agents.nix
      ../../modules/roles/paperclip.nix
      ../../modules/roles/hermes-agents.nix
      ../../modules/roles/agent-egress.nix
      ../../modules/roles/sqlite-backup.nix
      ../../modules/roles/beszel-agent.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "agents";
    stateVersion = "26.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  # The MAC is fixed in Terraform; OPNsense keeps a DHCP reservation for it,
  # so the address survives migration and HA recovery.
  networking.useDHCP = lib.mkDefault true;

  profiles.server = {
    # Only the operator's Mac Mini key; lab controllers are not trusted here.
    authorizedKeys = [ macMiniKey ];
    # Upgrades are deliberate: nix flake update + nix run .#switch.
    autoUpgrade.enable = false;
  };

  # No Home Manager user environment: keeps the closure small and the host
  # independent of user-tool downloads.
  home-manager.users = lib.mkForce { };

  # Agent runs and their tool calls are logged at length; keep a month, but
  # never let the journal crowd the disk.
  services.journald.extraConfig = ''
    SystemMaxUse=2G
    MaxRetentionSec=30day
  '';

  ############################################################
  ## Users and secrets (SOPS, host-scoped key)
  ############################################################
  # justin is key-only; root has a password for the Proxmox console only
  # (SSH root login is off).
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

  sops = {
    defaultSopsFile = ../../secrets/hosts/agents.yaml;
    # Dedicated host identity, installed by `nix run .#install` with
    # HOST_AGE_KEY_FILE. The operator key is never copied to this host.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];

    secrets."root/console-password-hash".neededForUsers = true;
  };

  ############################################################
  ## Workloads
  ############################################################
  # Podman, not Docker: no daemon holding a root socket, and nothing here
  # gets a container socket.
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  roles.paperclip = {
    enable = true;
    image = "ghcr.io/paperclipai/paperclip:2026.1023.0@sha256:40f46940c4612ead131aebe6079cd4651f8cd1434af49f7c621887f4a452a62e";
    publicUrl = "https://paperclip.servicestack.xyz";
    # Sign-up stays off (the role's default) now that the board is claimed. A
    # fresh instance needs it on once to accept the bootstrap invite
    # (docs/agents/REFERENCE.md, "First start").
  };

  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
  };

  # Alerts from Paperclip's state (./agent-watch.nix). Its three secrets are
  # in SOPS (docs/agents/REFERENCE.md, "Monitoring").
  agents.watch.enable = true;

  # The TrueNAS share for ./backup.nix, by address so the mount never waits
  # on DNS.
  agents.backup.nfsDevice = "10.0.0.20:/mnt/Main/backups/agent-backups";

  ############################################################
  ## Guards
  ############################################################
  # The exposure policy. .#checks.<system>.agents-exposure-guards breaks
  # each of these and fails unless evaluation refuses it.
  assertions = [
    {
      assertion = publicTcpPorts == [ 22 80 443 ];
      message = "agents: public TCP ports must be exactly 22, 80, 443 (got ${toString publicTcpPorts}).";
    }
    {
      assertion = publicUdpPorts == [ ];
      message = "agents: no public UDP ports (got ${toString publicUdpPorts}).";
    }
    {
      assertion = interfaceRules == { } && trustedInterfaces == [ ];
      message = "agents: no per-interface firewall openings or trusted interfaces (got ${toString (lib.attrNames interfaceRules ++ trustedInterfaces)}).";
    }
    {
      assertion = !config.virtualisation.docker.enable;
      message = "agents: no Docker; containers run under Podman.";
    }
    {
      assertion = exposedContainers == [ ];
      message = "agents: every container must use the host network, bind 127.0.0.1 and publish nothing (got ${toString exposedContainers}).";
    }
    {
      assertion = socketMounts == [ ];
      message = "agents: no container gets a container-engine socket (got ${toString socketMounts}).";
    }
    {
      assertion = unfilteredAgents == [ ];
      message = "agents: every Hermes agent goes through the egress filter (not covered: ${toString unfilteredAgents}).";
    }
    {
      assertion = !config.services.postgresql.enableTCPIP;
      message = "agents: PostgreSQL listens on the socket and localhost only.";
    }
    {
      assertion = paperclipEnv.PAPERCLIP_DEPLOYMENT_MODE == "authenticated"
        && paperclipEnv.PAPERCLIP_DEPLOYMENT_EXPOSURE == "private";
      message = "agents: Paperclip runs authenticated/private; local_trusted treats every request as the admin.";
    }
    {
      assertion = (paperclipEnv.PAPERCLIP_TELEMETRY_DISABLED or "") == "1";
      message = "agents: Paperclip's telemetry stays off.";
    }
    {
      assertion = !config.sops.validateSopsFiles || builtins.pathExists config.sops.defaultSopsFile;
      message = ''
        agents: secrets/hosts/agents.yaml doesn't exist yet. Generate the
        host age key, add its recipient to .sops.yaml, create the file with
        sops and `git add` it (docs/agents/REFERENCE.md, "Secrets").
      '';
    }
  ];
}
