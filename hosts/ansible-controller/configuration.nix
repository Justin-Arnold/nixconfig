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

  # private key -> ~/.ssh/ansible_controller (0400)
sops.secrets."ssh/ansible_controller/private" = {
  sopsFile = ../../secrets/ssh.yaml;
  format   = "yaml";
  path     = "/home/justin/.ssh/ansible_controller"; #todo use systemProfile.username
  mode     = "0400";
  owner    = "justin"; #todo use systemProfile.username
  group    = "users";
  neededForUsers = true;
};

# public key -> ~/.ssh/ansible_controller.pub (0644)
sops.secrets."ssh/ansible_controller/public" = {
  sopsFile = ../../secrets/ssh.yaml;
  format   = "yaml";
  path     = "/home/justin/.ssh/ansible_controller.pub"; #todo use systemProfile.username
  mode     = "0644";
  owner    = "justin"; #todo use systemProfile.username
  group    = "users";
  neededForUsers = true;
};

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}
