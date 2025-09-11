{ config, pkgs, lib, home-manager, ... }:
let
  site = "monitoring";      # your Checkmk site name
  httpPort = 8080;          # host port -> container :5000
in {
  imports = [
    ./hardware-configuration.nix
    ../../modules/common
    ../../modules/profiles
    ../../modules/platforms/nixos.nix
    ../../modules/roles/docker.nix
  ];

  systemProfile = {
    hostname = "gitea";
    stateVersion = "25.05";
    isServer = true;
  };

  virtualisation.oci-containers.containers.monitoring = {
    image = "docker.gitea.com/gitea:latest";
    autoStart = true;
    ports = [ 
      "${toString httpPort}:5000"
      "8000:8000"
    ];
    volumes = [
      "monitoring:/omd/sites"
    ];
    # If you used sops above:
    # environmentFiles = [ "/run/secrets/checkmk.env" ];

    # If you prefer inline vars instead of sops:
    environment = {
      CMK_SITE_ID = site;
      CMK_LIVESTATUS_TCP = "on";
      CMK_PASSWORD= "change-me";  # or move to sops
    };

    extraOptions = [
      # site tmpfs improves performance; matches container docs
      "--tmpfs" "/opt/omd/sites/cmk/tmp:uid=1000,gid=1000"
    ];
  };

  networking.firewall.allowedTCPPorts = [ httpPort ];

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}