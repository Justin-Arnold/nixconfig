{pkgs, lib, config, ...}:

let
  cfg = config.modules.roles.nixos.desktopEnvironments.hyprland;
in {
  options.modules.roles.nixos.desktopEnvironments.hyprland = {
    enable = lib.mkEnableOption "Hyprland desktop environment";
  };

  config = lib.mkIf cfg.enable {
    programs.hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    # Nix-packaged Electron apps run on native Wayland only with this set.
    # Without it some (Codex/ChatGPT desktop) fall back to XWayland, which
    # draws them at 1x and stretches them on the 1.25-scaled DualUps.
    environment.sessionVariables.NIXOS_OZONE_WL = "1";

    environment.systemPackages = [
      pkgs.hyprshell
    ];

    home-manager.users.${config.systemProfile.username} = {...}: {
      imports = [
        ../../../../home/apps/hyprland.nix
        ../../../../home/apps/hyprpaper.nix
        ../../../../home/apps/wayle.nix
      ];
    };
  };
}
