{ config, pkgs, ... }:
{
  imports = [ 
    ./hardware-configuration.nix
    ../../modules/common
    ../../modules/profiles/server.nix
    ../../modules/platforms/nixos
  ];

  systemProfile = {
    hostname = "vikunja";
    stateVersion = "25.05";
    isServer = true;
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 3456 ];
  };

  services.vikunja = {
    enable = true;
    frontendScheme = "http";
    frontendHostname = "localhost";    
  };
}