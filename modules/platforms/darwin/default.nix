{ home-manager, pkgs, lib, sops-nix, ... }:
{
  config = lib.mkIf config.systemProfile.isDarwin {
    imports = [ 
      ./dock.nix
      ./homebrew.nix
      ./window-manager.nix

      home-manager.darwinModules.home-manager
    ];

    system.stateVersion = config.systemProfile.stateVersionDarwin;

    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.backupFileExtension = "backup";
    home-manager.sharedModules = [
      sops-nix.homeManagerModules.sops
    ];
    home-manager.users.${config.systemProfile.username} = {...}: {
      imports = [ 
        ../../home/roles/base.nix
      ];
    };
  }
}