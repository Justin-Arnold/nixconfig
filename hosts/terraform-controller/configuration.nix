{ config, pkgs, lib, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/profiles/base.nix
      ../../modules/profiles/server.nix
      ../../modules/roles/terraform.nix
      ../../modules/platforms/nixos.nix
    ];

  networking.hostName = "terraform-controller";
  system.stateVersion = "25.05";
}
