# automation: n8n, the router between the lab's systems, a NixOS VM on the
# Proxmox cluster (n8n.nix). It takes GitHub's webhook deliveries and turns
# them into Paperclip routines or alerts, so the deterministic part of a job
# never costs a model run. It holds the GitHub webhook secret, one secret per
# Paperclip routine it may start and its own Alerta key, and none of the
# agents' keys. Like the other lab VMs it can move between nodes: disk and
# cloud-init drive on nas-shared, an HA resource, a CPU model every node has
# (infra/terranix/hosts/automation.nix). See docs/automation/REFERENCE.md.
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
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./n8n.nix
      ./endpoints.nix
      ./backup.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/sqlite-backup.nix
      ../../modules/roles/beszel-agent.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "automation";
    stateVersion = "26.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  # The MAC is fixed in Terraform; OPNsense keeps a DHCP reservation for it
  # (10.0.0.155), so the address survives migration and HA recovery.
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

  ############################################################
  ## Users and secrets (SOPS, host-scoped key)
  ############################################################
  # justin is key-only; root has a password for the Proxmox console only
  # (SSH root login is off).
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

  sops = {
    defaultSopsFile = ../../secrets/hosts/automation.yaml;
    # Dedicated host identity, installed by `nix run .#install` with
    # HOST_AGE_KEY_FILE. The operator key is never copied to this host.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];

    secrets."root/console-password-hash".neededForUsers = true;
  };

  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
  };

  # The TrueNAS share for ./backup.nix, by address so the mount never waits
  # on DNS.
  automation.backup.nfsDevice = "10.0.0.20:/mnt/Main/backups/automation-backups";

  ############################################################
  ## Guards
  ############################################################
  # The exposure policy. .#checks.<system>.automation-exposure-guards breaks
  # each of these and fails unless evaluation refuses it.
  assertions = [
    {
      assertion = publicTcpPorts == [ 22 80 443 ];
      message = "automation: public TCP ports must be exactly 22, 80, 443 (got ${toString publicTcpPorts}).";
    }
    {
      assertion = publicUdpPorts == [ ];
      message = "automation: no public UDP ports (got ${toString publicUdpPorts}).";
    }
    {
      assertion = interfaceRules == { } && trustedInterfaces == [ ];
      message = "automation: no per-interface firewall openings or trusted interfaces (got ${toString (lib.attrNames interfaceRules ++ trustedInterfaces)}).";
    }
    {
      assertion = !config.virtualisation.docker.enable && !config.virtualisation.podman.enable;
      message = "automation: no container runtime; n8n runs as a NixOS service.";
    }
    {
      assertion = !config.sops.validateSopsFiles || builtins.pathExists config.sops.defaultSopsFile;
      message = ''
        automation: secrets/hosts/automation.yaml doesn't exist yet. Generate
        the host age key, add its recipient to .sops.yaml, create the file with
        sops and `git add` it (docs/automation/REFERENCE.md, "Secrets").
      '';
    }
  ];
}
