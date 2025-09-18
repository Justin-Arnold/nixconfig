{ home-manager, pkgs, lib, sops-nix, config, ... }:
{
  imports = [ 
    home-manager.nixosModules.home-manager
  ];

  system.stateVersion = config.systemProfile.stateVersion;

  ############################################################
  ## User Configuration
  ############################################################
  users.users."${config.systemProfile.username}" = {
    isNormalUser = true; 
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  programs.ssh.startAgent = true;
  programs.ssh.extraConfig = ''
    Host *
        AddKeysToAgent yes
        IdentitiesOnly yes
  '';
  
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