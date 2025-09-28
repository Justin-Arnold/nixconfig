{pkgs, lib, config, ...}:

let
  cfg = config.modules.roles.nixos.desktopEnvironments.hyprland;
in {
  options.modules.roles.nixos.desktopEnvironments.hyprland = lib.mkOption {
    enable = lib.mkEnableOption "Hyprland desktop environment";
  };

  config = lib.mkIf cfg.enable {
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
  };
}