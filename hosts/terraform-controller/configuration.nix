{ config, pkgs, lib, ... }:

{
  imports =
    [ 
      ../../modules/profiles/base.nix
      ../../modules/profiles/server.nix
      ../../modules/roles/terraform.nix
      ../../modules/platform/nixos.nix
    ];

  networking.hostName = "terraform-controller";
  system.stateVersion = "25.05";
}
