{ home-manager, pkgs, lib, sops-nix, zen-browser, config, ... }:

{
  imports = [ 
    ./dock.nix
    ./homebrew.nix
    ./window-manager.nix

    home-manager.darwinModules.home-manager
  ];

  system.stateVersion = config.systemProfile.stateVersionDarwin;
  system.primaryUser = config.systemProfile.username;

  modules.apps.onepassword.enable = true;
  
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";
  home-manager.extraSpecialArgs = { inherit zen-browser; };
  home-manager.sharedModules = [
    sops-nix.homeManagerModules.sops
  ];
  home-manager.users.${config.systemProfile.username} = {...}: {
    imports = [ 
      ../../../home/roles/base.nix
    ];
  };
}