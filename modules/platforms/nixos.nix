{ home-manager, ... }:
{
  imports = [ home-manager.nixosModules.home-manager ];

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";
  # this hits *all* home-manager users on the system
  home-manager.sharedModules = [
    ../../home/roles/base.nix
  ];
}