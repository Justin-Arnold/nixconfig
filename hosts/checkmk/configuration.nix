{ config, pkgs, lib, ... }:
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
    ../../modules/roles/checkmk.nix
  ];

  systemProfile = {
    hostname = "checkmk";
    stateVersion = "25.05";
    isServer = true;
  };

  roles.docker = {
    enable = true;
  };

  # Persistent data directories with container-friendly ownership
  systemd.tmpfiles.rules = [
    "d /var/lib/checkmk 0750 1000 1000 -"
    "d /var/log/checkmk 0750 root root -"
  ];

  # (Optional, recommended) keep secrets out of Git:
  # sops-nix dotenv with e.g.:
  #   CMK_SITE_ID=monitoring
  #   CMK_PASSWORD=<initial-admin-password>
  #   CMK_LIVESTATUS_TCP=on
  # and then reference the env file below.
  # sops.secrets."checkmk.env" = {
  #   sopsFile = ../../secrets/checkmk.env;
  #   format   = "dotenv";
  #   mode     = "0400";
  #   owner    = "root";
  # };

  virtualisation.oci-containers.containers.monitoring = {
    image = "checkmk/check-mk-raw:latest";  # pick your preferred tag
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
      "--restart=unless-stopped"
    ];
  };

  networking.firewall.allowedTCPPorts = [ httpPort ];
}