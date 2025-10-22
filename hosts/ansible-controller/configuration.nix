{ config, pkgs, lib, sops-nix, home-manager, ... }:
{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
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
    path     = "/home/justin/.ssh/id_ed25519"; #todo use systemProfile.username
    mode     = "0600";
    owner    = "justin"; #todo use systemProfile.username
    group    = "users";
  };

  # public key -> ~/.ssh/ansible_controller.pub (0644)
  sops.secrets."ssh/ansible_controller/public" = {
    sopsFile = ../../secrets/ssh.yaml;
    format   = "yaml";
    path     = "/home/justin/.ssh/id_ed25519.pub"; #todo use systemProfile.username
    mode     = "0644";
    owner    = "justin"; #todo use systemProfile.username
    group    = "users";
  };

  # Ansible default to this key
  environment.etc."ansible/ansible.cfg".text = ''
    [defaults]
    private_key_file = /home/justin/.ssh/id_ed25519
    host_key_checking = False
    interpreter_python = auto_silent
  '';

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
      ../../home/apps/ansible
    ];
  };
}
