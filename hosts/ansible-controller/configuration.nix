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

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";

  sops.secrets."ssh/ansible_controller/private" = {
    sopsFile = ../../secrets/ssh.yaml;
    format   = "yaml";
    key      = "ssh.ansible_controller.private";
    path     = "/home/justin/.ssh/ansible_controller";
    mode     = "0400";
    owner    = "justin";
    group    = "users";
  };

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}
