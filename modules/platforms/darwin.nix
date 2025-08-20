{ home-manager, ... }:
{
  imports = [ home-manager.darwinModules.home-manager ];
  
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;

  home-manager.sharedModules = [
    ../../home/roles/base.nix
  ];
}