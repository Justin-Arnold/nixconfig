{ config, pkgs, lib, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/profiles/base.nix
    ../../modules/profiles/server.nix
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
}