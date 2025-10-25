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
  sops.defaultSopsFile = ../../secrets/secrets.yaml;

  sops.secrets = {
    "onepassword/OP_API_TOKEN" = { };
    "onepassword/OP_SERVICE_ACCOUNT_TOKEN" = { };
    "onepassword/OP_CONNECT_TOKEN" = { };

    "ssh/ansible_controller/private" = {
      mode = "0600";
      owner = "justin";
      group = "users";
    };
    "ssh/ansible_controller/public" = {
      mode = "0644";
      owner = "justin";
      group = "users";
    };
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

    programs.zsh.initContent = ''
      export OP_API_TOKEN=$(cat ${config.sops.secrets."onepassword/OP_API_TOKEN".path})
      export OP_SERVICE_ACCOUNT_TOKEN=$(cat ${config.sops.secrets."onepassword/OP_SERVICE_ACCOUNT_TOKEN".path})
      export OP_CONNECT_TOKEN=$(cat ${config.sops.secrets."onepassword/OP_CONNECT_TOKEN".path})
    '';
  };
}
