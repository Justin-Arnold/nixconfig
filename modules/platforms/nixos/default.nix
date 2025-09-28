{ home-manager, pkgs, inputs, lib, sops-nix, zen-browser, config, ... }:
{
  imports = [ 
    home-manager.nixosModules.home-manager
    ./desktopEnvironments
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

  modules = {
    apps.onepassword = {
      enable = true;
      polkit.enable = true
    };
    
    platforms.nixos.desktopEnvironments = {
      hyprland = {
        enable = config.systemProfile.hasGui;
      }
    }
  };

  programs.zsh.enable = true;
  #programs.ssh.startAgent = true;
  #programs.ssh.extraConfig = ''
   # Host *
   #     AddKeysToAgent yes
   #     IdentitiesOnly yes
  #'';
  
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";
  home-manager.extraSpecialArgs = { inherit zen-browser; };
  home-manager.sharedModules = [
    sops-nix.homeManagerModules.sops
    inputs._1password-shell-plugins.hmModules.default
  ];
  home-manager.users.${config.systemProfile.username} = {...}: {
    imports = [
      ../../../home/roles/base.nix
      ../../../home/roles/nixos.nix
    ];
  };
}
