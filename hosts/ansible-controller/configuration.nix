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

  sops.templates."onepassword-env.sh" = {
    content = ''
      export OP_API_TOKEN="${config.sops.placeholder."onepassword/OP_API_TOKEN"}"
      export OP_SERVICE_ACCOUNT_TOKEN="${config.sops.placeholder."onepassword/OP_SERVICE_ACCOUNT_TOKEN"}"
      export OP_CONNECT_TOKEN="${config.sops.placeholder."onepassword/OP_CONNECT_TOKEN"}"
    '';
    mode = "0400";
    owner = "justin";
    group = "users";
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
      if [ -f ${config.sops.templates."onepassword-env.sh".path} ]; then
        source ${config.sops.templates."onepassword-env.sh".path}
      fi
    '';
  };
}
