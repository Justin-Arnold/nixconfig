{ config, pkgs, lib, home-manager, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common
  ];

  systemProfile = {
    hostname = "nocodb";
    stateVersion = "25.05";
    isServer = true;
  };

  virtualisation.oci-containers.containers.root_db = {
    image = "postgres:16.6";
    autoStart = true;
    environment = {
      POSTGRES_DB = "root_db";
      POSTGRES_PASSWORD = "password";
      POSTGRES_USER = "postgres";
    };
    volumes = [
      "db_data:/var/lib/postgresql/data"
    ];
    # Note: Health checks and restart policies are handled automatically by systemd
  };

  virtualisation.oci-containers.containers.nocodb = {
    image = "nocodb/nocodb:latest";
    autoStart = true;
    ports = [
      "8080:8080"
    ];
    environment = {
      NC_DB = "pg://root_db:5432?u=postgres&p=password&d=root_db";
    };
    volumes = [
      "nc_data:/usr/app/data"
    ];
    # Dependencies are handled by systemd ordering - see below
  };

  # Set up proper service dependencies
  systemd.services.podman-nocodb = {
    after = [ "podman-root_db.service" ];
    requires = [ "podman-root_db.service" ];
  };

  systemd.services.podman-root_db.preStart = ''
    ${pkgs.podman}/bin/podman network exists nocodb-network || \
    ${pkgs.podman}/bin/podman network create nocodb-network
  '';

  virtualisation.oci-containers.containers.root_db.extraOptions = [
    "--network=nocodb-network"
  ];

  virtualisation.oci-containers.containers.nocodb.extraOptions = [
    "--network=nocodb-network"
  ];

  networking.firewall.allowedTCPPorts = [ 8080 ];

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}