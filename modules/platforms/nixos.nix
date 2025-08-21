{ home-manager, pkgs, lib, ... }:
{
  imports = [ home-manager.nixosModules.home-manager ];
  
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";
  home-manager.sharedModules = [
    ../../home/roles/base.nix
  ];
}