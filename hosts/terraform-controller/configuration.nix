{ config, pkgs, lib, sops-nix, home-manager, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/roles/terraform.nix

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

  sops.secrets."hetzner-pangolin.env" = {
    sopsFile = ../../secrets/hetzner-pangolin.env;
    format = "dotenv";
    mode = "0400";
    owner = "justin";
    group = "users";
  };

  sops.secrets."onepassword.env" = {
    sopsFile = ../../secrets/onepassword.env;
    format = "dotenv";
    mode = "0400";
    owner = "justin";
    group = "users";
  };


  sops.secrets."ssh/ansible_controller/public" = {
    sopsFile = ../../secrets/ssh.yaml;
    format = "yaml";
    path = "/run/secrets/ssh-ansible-controller-public";
    mode = "0644";
    owner = "justin";
    group = "users";
  };

  sops.secrets."ssh/macmini/public" = {
    sopsFile = ../../secrets/ssh.yaml;
    format = "yaml"; 
    path = "/run/secrets/ssh-macmini-public";
    mode = "0644";
    owner = "justin";
    group = "users";
  };

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/apps/terraform
      ../../home/roles/base.nix
    ];
  };
}
