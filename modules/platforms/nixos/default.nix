{ home-manager, pkgs, lib, sops-nix, ... }:
{
  config = lib.mkIf config.systemProfile.isNixos {
    imports = [ 
      home-manager.nixosModules.home-manager
    ];

    system.stateVersion = config.systemProfile.stateVersion;
    
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
  };
}