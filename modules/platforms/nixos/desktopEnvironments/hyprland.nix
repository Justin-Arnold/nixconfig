{pkgs, lib, congif, ...}:

let
  cfg = config.modules.roles.nixos.desktopEnvironments.hyprland;
in {
  options.modules.roles.nixos.desktopEnvironments.hyprland = lib.mkOption {
    enable = lib.mkEnableOption "Hyprland desktop environment";
  };

  config = lib.mkif cfg.enable {
    programs.hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    home-manager.users.${config.systemProfile.username} = {...}: {
      imports = [
        ../../../../home/apps/hyprland.nix
        ../../../../home/apps/hyrpaper.nix
        ../../../../home/apps/hyprpanel.nix
      ];
    };
  }  
}