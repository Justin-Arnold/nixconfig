# forge: the lab's own Git forge, Forgejo on a NixOS VM on the Proxmox
# cluster, for the LAN and the VPN only. It holds the vault's history (pushed
# by the agents host, hosts/agents/notes.nix), and later the agents' repos
# and Justin's private projects. There's no public DNS record and no Pangolin
# resource for it, no mirrors and no CI. Like the other lab VMs it can move
# between nodes: disk and cloud-init drive on nas-shared, an HA resource, a
# CPU model every node has (infra/terranix/hosts/forge.nix). Its install,
# secrets and backups are in Justin's vault, 02. Areas/Homelab/Hosts/forge.md.
{ config, lib, inputs, sops-nix, ... }:
let
  facts = import ./facts.nix;
  macMiniKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com";

  sopsFile = ../../secrets/hosts/forge.yaml;
  haveSecrets = builtins.pathExists sopsFile;

  fw = config.networking.firewall;
  interfaceRules = lib.filterAttrs
    (_: i: i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ] || i.allowedTCPPortRanges != [ ] || i.allowedUDPPortRanges != [ ])
    fw.interfaces;
  # The NixOS firewall always trusts the loopback interface.
  trustedInterfaces = lib.subtractLists [ "lo" ] fw.trustedInterfaces;

  # Every new connection to this host: the Newt is dropped first, then SSH
  # and nginx are open to the LAN and the VPN, and nothing else is.
  inboundRules = ''
    ip saddr ${facts.pangolinNewt} counter drop comment "Pangolin's Newt"
    ip saddr { ${lib.concatStringsSep ", " facts.allowedSources} } tcp dport { 22, 80, 443 } accept comment "the LAN and the VPN"
  '';
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./forgejo.nix
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
    hostname = "forge";
    stateVersion = "26.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  # The MAC is fixed in Terraform; OPNsense keeps a DHCP reservation for it
  # (facts.nix), so the address survives migration and HA recovery.
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
  ## Network
  ############################################################
  # Nothing is open to every source; inboundRules says who reaches what.
  # Forced empty because profiles.server opens 22 to everyone, and so would
  # any module's openFirewall: those openings are dropped here, and a new one
  # has to be written into inboundRules.
  networking.nftables.enable = true;
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];
  networking.firewall.extraInputRules = inboundRules;

  # SSH is for justin and for git (as forgejo, which Forgejo's authorized_keys
  # pins to `forgejo serv`).
  services.openssh.settings.AllowUsers = [ config.systemProfile.username config.services.forgejo.user ];

  ############################################################
  ## Users and secrets (SOPS, host-scoped key)
  ############################################################
  # justin is key-only; root has a password for the Proxmox console only
  # (SSH root login is off).
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

  sops = {
    # Until secrets/hosts/forge.yaml exists the host still evaluates, with a
    # warning, and `nix run .#install` refuses to install it. The path goes in
    # as a string then, since Nix can't copy a missing file to the store.
    defaultSopsFile = if haveSecrets then sopsFile else toString sopsFile;
    validateSopsFiles = haveSecrets;
    # Dedicated host identity, installed by `nix run .#install` with
    # HOST_AGE_KEY_FILE. The operator key is never copied to this host.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];

    secrets."root/console-password-hash".neededForUsers = true;
  };

  warnings = lib.optional (!haveSecrets) ''
    forge: secrets/hosts/forge.yaml doesn't exist yet, so this host can't be
    installed. Generate the host age key, add its recipient to .sops.yaml,
    create the file with sops and `git add` it
    (02. Areas/Homelab/Hosts/forge.md in Justin's vault, "Secrets").
  '';

  ############################################################
  ## Monitoring
  ############################################################
  # Reports to the Beszel hub on the dashboard VM.
  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
  };

  # The TrueNAS share for ./backup.nix, by address so the mount never waits
  # on DNS.
  forge.backup.nfsDevice = "10.0.0.20:/mnt/Main/backups/forge-backups";

  ############################################################
  ## Guards
  ############################################################
  # The exposure policy: the build fails if any of these stops holding.
  assertions = [
    {
      # allowedTCPPorts is forced empty above; the rest isn't.
      assertion = config.networking.nftables.enable && fw.allowedUDPPorts == [ ]
        && fw.allowedTCPPortRanges == [ ] && fw.allowedUDPPortRanges == [ ];
      message = "forge: nothing is open to every source (got UDP ${toString fw.allowedUDPPorts} and port ranges); openings go in inboundRules.";
    }
    {
      assertion = interfaceRules == { } && trustedInterfaces == [ ];
      message = "forge: no per-interface firewall openings or trusted interfaces (got ${toString (lib.attrNames interfaceRules ++ trustedInterfaces)}).";
    }
    {
      # Any other rule in extraInputRules is a new opening.
      assertion = fw.extraInputRules == inboundRules;
      message = "forge: the firewall drops Pangolin's Newt (${facts.pangolinNewt}) and accepts TCP 22, 80 and 443 from ${toString facts.allowedSources}, nothing else.";
    }
    {
      assertion = lib.hasPrefix "ip saddr ${facts.pangolinNewt} counter drop" inboundRules;
      message = "forge: the Newt's drop has to come first; nftables takes the first matching verdict.";
    }
    {
      assertion = !config.services.openssh.settings.PasswordAuthentication
        && !config.services.openssh.settings.KbdInteractiveAuthentication
        && config.services.openssh.settings.PermitRootLogin == "no";
      message = "forge: SSH is key-only, without root.";
    }
  ];
}
