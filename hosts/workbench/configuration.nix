# workbench: where the agents' work runs, a NixOS VM on the Proxmox cluster.
# The Hermes agents on the agents VM log in here over ssh, one Unix user
# each, and their terminal and file tools act on this machine: git
# worktrees, tests, rootless Podman. It's the other half of the agents VM's
# rule: generated code runs here, and nothing here is worth stealing except
# a GitHub token that can push agent/** branches to two repos.
#
# It's disposable. Work lives on pushed branches, so there's nothing to back
# up, and the disk sits on the node's local storage without HA
# (infra/terranix/hosts/workbench.nix). See docs/workbench/REFERENCE.md.
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

  # Every agent-* user, wherever it's declared.
  agentUsers = lib.filter (lib.hasPrefix "agent-") (lib.attrNames config.users.users);
  egress = config.roles.agentEgress;
  unfiltered = lib.filter (u: !(egress.enable && lib.elem u egress.users)) agentUsers
    ++ lib.optional (!(egress.enable && lib.elem "nixbld" egress.groups)) "nix's build users";
  inWheel = lib.filter (u: lib.elem "wheel" config.users.users.${u}.extraGroups
    || lib.elem u config.users.groups.wheel.members) agentUsers;
  sudoRules = lib.filter (r: lib.any (u: lib.elem u agentUsers) (r.users or [ ])) config.security.sudo.extraRules;
  trusted = config.nix.settings.trusted-users;
  trustedAgents = lib.filter (u: lib.elem u trusted) agentUsers;
  # Keys that aren't limited to the agents VM, or that allow forwarding or a pty.
  looseKeys = lib.concatMap (u: lib.filter (k: !(lib.hasPrefix ''restrict,from="10.0.0.152" '' k))
    config.users.users.${u}.openssh.authorizedKeys.keys) agentUsers;
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ./agents.nix
      ../../modules/roles/agent-egress.nix
      ../../modules/roles/beszel-agent.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "workbench";
    stateVersion = "26.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  # The MAC is fixed in Terraform; OPNsense keeps a DHCP reservation for it
  # (10.0.0.153), which the engineer's ssh terminal on agents points at.
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

  services.journald.settings.Journal = {
    SystemMaxUse = "2G";
    MaxRetentionSec = "30day";
  };

  ############################################################
  ## Users and secrets (SOPS, host-scoped key)
  ############################################################
  # justin is key-only; root has a password for the Proxmox console only
  # (SSH root login is off).
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

  sops = {
    defaultSopsFile = ../../secrets/hosts/workbench.yaml;
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
  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
  };

  # Agents' builds and their container images fill the disk; a week of
  # garbage is plenty.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };
  nix.optimise.automatic = true;

  ############################################################
  ## Guards
  ############################################################
  # The exposure policy. .#checks.<system>.workbench-exposure-guards breaks
  # each of these and fails unless evaluation refuses it.
  assertions = [
    {
      assertion = publicTcpPorts == [ 22 ];
      message = "workbench: the only public TCP port is 22 (got ${toString publicTcpPorts}).";
    }
    {
      assertion = publicUdpPorts == [ ];
      message = "workbench: no public UDP ports (got ${toString publicUdpPorts}).";
    }
    {
      assertion = interfaceRules == { } && trustedInterfaces == [ ];
      message = "workbench: no per-interface firewall openings or trusted interfaces (got ${toString (lib.attrNames interfaceRules ++ trustedInterfaces)}).";
    }
    {
      assertion = !config.virtualisation.docker.enable && !config.virtualisation.podman.dockerSocket.enable;
      message = "workbench: no Docker and no container socket; agents get rootless Podman.";
    }
    {
      assertion = inWheel == [ ] && sudoRules == [ ];
      message = "workbench: agents get no sudo (got ${toString (inWheel ++ lib.concatMap (r: r.users or [ ]) sudoRules)}).";
    }
    {
      assertion = trustedAgents == [ ] && !(lib.any (t: t == "*" || lib.hasPrefix "@" t && t != "@wheel") trusted);
      message = "workbench: agents aren't trusted by the nix daemon; a trusted user can turn off the sandbox or add caches.";
    }
    {
      assertion = (config.nix.settings.sandbox or true) == true;
      message = "workbench: nix builds stay sandboxed.";
    }
    {
      assertion = unfiltered == [ ];
      message = "workbench: every agent user and nix's build users go through the egress filter (not covered: ${lib.concatStringsSep ", " unfiltered}).";
    }
    {
      assertion = looseKeys == [ ];
      message = ''workbench: agent ssh keys start with restrict,from="10.0.0.152" (the agents VM) and allow nothing more.'';
    }
    {
      assertion = !config.sops.validateSopsFiles || builtins.pathExists config.sops.defaultSopsFile;
      message = ''
        workbench: secrets/hosts/workbench.yaml doesn't exist yet. Generate
        the host age key, add its recipient to .sops.yaml, create the file
        with sops and `git add` it (docs/workbench/REFERENCE.md, "Secrets").
      '';
    }
  ];
}
