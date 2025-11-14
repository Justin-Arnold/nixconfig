{ config, pkgs, ... }:
{
  imports = [ 
    ./hardware-configuration.nix
    ../../modules/common
    ../../modules/profiles/server.nix
    ../../modules/platforms/nixos
  ];

  environment.systemPackages = with pkgs; [

  ];
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
  };

  services.vikunja = {
    enable = true;
    frontendScheme = "http";
    frontendHostname = "localhost";    
  };
}