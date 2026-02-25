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

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "ollama";
    stateVersion = "25.05";
    isServer = true;
  };
}
