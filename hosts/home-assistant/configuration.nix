# Fresh HA Core, never the old HAOS VM. See docs/home-assistant/REFERENCE.md.
{
  config,
  lib,
  inputs,
  sops-nix,
  ...
}:
let
  fw = config.networking.firewall;
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./home-assistant.nix
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
    hostname = "home-assistant";
    stateVersion = "26.05";
    isServer = true;
  };
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];
  networking.useDHCP = lib.mkDefault true;
  profiles.server = {
    authorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com"
    ];
    # Updates arrive as reviewed PRs; no autonomous live switch is approved.
    autoUpgrade.enable = false;
  };
  home-manager.users = lib.mkForce { };
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;
  sops = {
    # String construction allows test-only overrides before this file exists.
    # The deployed configuration still validates the real encrypted file.
    defaultSopsFile = ../../secrets/hosts + "/home-assistant.yaml";
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];
    secrets."root/console-password-hash".neededForUsers = true;
  };
  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
  };
  assertions = [
    {
      assertion =
        lib.sort lib.lessThan (lib.unique fw.allowedTCPPorts) == [
          22
          80
          443
        ];
      message = "home-assistant: only SSH/HTTP/HTTPS may be globally opened.";
    }
    {
      assertion =
        fw.allowedUDPPorts == [ ] && fw.allowedTCPPortRanges == [ ] && fw.allowedUDPPortRanges == [ ];
      message = "home-assistant: radio ports must use the source-scoped rules, never global openings.";
    }
    {
      assertion =
        lib.all (
          i:
          i.allowedTCPPorts == [ ]
          && i.allowedUDPPorts == [ ]
          && i.allowedTCPPortRanges == [ ]
          && i.allowedUDPPortRanges == [ ]
        ) (lib.attrValues fw.interfaces)
        && lib.subtractLists [ "lo" ] fw.trustedInterfaces == [ ];
      message = "home-assistant: no interface-wide openings or trusted interfaces.";
    }
    {
      assertion = !config.virtualisation.docker.enable && !config.virtualisation.podman.enable;
      message = "home-assistant: native services only, no container bypass of the firewall.";
    }
    {
      assertion = !config.profiles.server.autoUpgrade.enable && !config.system.autoUpgrade.enable;
      message = "home-assistant: unattended live switches require a separately approved policy.";
    }
    {
      assertion = !config.sops.validateSopsFiles || builtins.pathExists config.sops.defaultSopsFile;
      message = "home-assistant: Justin must securely create secrets/hosts/home-assistant.yaml before provisioning; see REFERENCE.md.";
    }
  ];
}
