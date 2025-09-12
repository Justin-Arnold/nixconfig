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

  services.postgresql = {
    enable = true;

    ensureDatabases = [ "nocodb" ];
    ensureUsers = [{
      name = config.systemProfile.username;
      ensureDBOwnership = true;
    }];

    package = with pkgs; postgresql_15;
    authentication = lib.mkForce ''
        #type database DBuser  origin-address auth-method
        # unix socket
        local all      all                    trust
        # ipv4
        host  all      all     127.0.0.1/32   trust
        # ipv6
        host  all      all     ::1/128        trust
    '';

    settings.log_timezone = config.systemProfile.timeZone;
  };

  services.nocodb = {
    enable = true;
    environments = {
      DB_URL="postgres:///nocodb?host=/run/postgresql";
      NC_PUBLIC_URL="http://nocodb.internal";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}