{ config, pkgs, lib, sops-nix, home-manager, ... }:
{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/profiles
      ../../modules/platforms/nixos.nix
      ../../modules/roles/ansible.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "ansible-controller";
    stateVersion = "25.05";
    isServer = true;
  };

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}
