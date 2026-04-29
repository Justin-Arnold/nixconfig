{ config, pkgs, inputs, ... }:
{
  sops = {
    age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
    defaultSopsFile = ../../secrets/secrets.yaml;

    secrets = {
      "proxmox/PROXMOX_VE_ENDPOINT" = { };
      "proxmox/PROXMOX_VE_API_TOKEN" = { };
    };

    templates."proxmox.env".content = ''
      export PROXMOX_VE_ENDPOINT="${config.sops.placeholder."proxmox/PROXMOX_VE_ENDPOINT"}"
      export PROXMOX_VE_API_TOKEN="${config.sops.placeholder."proxmox/PROXMOX_VE_API_TOKEN"}"
      export PROXMOX_VE_INSECURE="true"
    '';
  };

  home.packages = [
    pkgs.curl
    pkgs.jq
    pkgs.openssh
    pkgs.terraform
    inputs.nixos-anywhere.packages.${pkgs.system}.default
    inputs.terranix.packages.${pkgs.system}.default
  ];

  programs.zsh.initContent = ''
    if [ -f ${config.sops.templates."proxmox.env".path} ]; then
      source ${config.sops.templates."proxmox.env".path}
    fi
  '';
}
