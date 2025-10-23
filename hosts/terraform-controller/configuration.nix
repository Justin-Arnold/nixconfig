{ config, pkgs, lib, sops-nix, home-manager, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/terraform.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "terraform-controller";
    stateVersion = "25.05";
    isServer = true;
  };

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/secrets.yaml;

  sops.secrets = {
    "proxmox/PROXMOX_VE_ENDPOINT" = { };
    "proxmox/PROXMOX_VE_API_TOKEN" = { };
    "hetzner/pangolin/HCLOUD_TOKEN" = { };
    "onepassword/OP_SERVICE_ACCOUNT_TOKEN" = { };
    "nocodb/NC_AUTH_JWT_SECRET" = { };
    "github/cli_token" = { };
    
    "ssh/ansible_controller/public" = {
      mode = "0644";
      owner = "justin";
      group = "users";
    };
    "ssh/ansible_controller/private" = {
      mode = "0600";
      owner = "justin";
      group = "users";
    };
    "ssh/macmini/public" = {
      mode = "0644";
      owner = "justin";
      group = "users";
    };
    "ssh/macmini/private" = {
      mode = "0600";
      owner = "justin";
      group = "users";
    };
  };

  sops.templates."proxmox.env" = {
    path = "/run/secrets-env/proxmox.env";
    content = ''
      PROXMOX_VE_ENDPOINT=${config.sops.placeholder."proxmox/PROXMOX_VE_ENDPOINT"}
      PROXMOX_VE_API_TOKEN=${config.sops.placeholder."proxmox/PROXMOX_VE_API_TOKEN"}
      PROXMOX_VE_INSECURE=true
    '';
    mode = "0400";
    owner = "justin";
    group = "users";
  };

  sops.templates."hetzner-pangolin.env" = {
    path = "/run/secrets-env/hetzner-pangolin.env";
    content = ''
      HCLOUD_TOKEN=${config.sops.placeholder."hetzner/pangolin/HCLOUD_TOKEN"}
    '';
    mode = "0400";
    owner = "justin";
    group = "users";
  };

  sops.templates."onepassword.env" = {
    path = "/run/secrets-env/onepassword.env";
    content = ''
      OP_SERVICE_ACCOUNT_TOKEN=${config.sops.placeholder."onepassword/OP_SERVICE_ACCOUNT_TOKEN"}
    '';
    mode = "0400";
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
