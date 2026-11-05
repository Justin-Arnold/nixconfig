{ config, pkgs, lib, sops-nix, ... }:
{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/ollama.nix
      ../../modules/roles/ai-voice.nix
      ../../modules/roles/beszel-agent.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "ollama";
    stateVersion = "25.05";
    isServer = true;
  };

  # Reports CPU, memory, disks and the RTX 3090 (nvidia-smi) to the Beszel hub
  # on dashboard. It stays off until the hub key exists; before turning it on,
  # check the operator age key is really on this host:
  #   ssh ollama sudo test -f /home/justin/.config/sops/age/keys.txt
  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
  };
  sops = lib.mkIf (config.roles.beszelAgent.hubPublicKey != null) {
    age.keyFile = "/home/justin/.config/sops/age/keys.txt";
    defaultSopsFile = ../../secrets/secrets.yaml;
  };
}
