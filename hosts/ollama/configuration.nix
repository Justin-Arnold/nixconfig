{ config, pkgs, lib, sops-nix, home-manager, ... }:
{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/roles/ollama.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "ollama";
    stateVersion = "25.05";
    isServer = true;
  };

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}
