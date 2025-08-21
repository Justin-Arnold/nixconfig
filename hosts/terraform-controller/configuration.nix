{ config, pkgs, lib, sops-nix, home-manager, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/roles/terraform.nix

      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "terraform-controller";
    stateVersion = "25.05";
    isServer = true;
  };

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";

  sops.secrets."proxmox.env" = {
    sopsFile = ../../secrets/proxmox.env;
    format   = "dotenv"; 
    mode = "0400";
    owner = "justin";
    group    = "users";
  };

  home-manager.users.justin = { ... }: {
    imports = [ 
        ../../home/terraform-infra/ansible.nix
        ../../home/apps/neovim.nix
        ../../home/apps/zsh.nix
    ];
  };
}
