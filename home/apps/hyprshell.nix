{ config, pkgs, lib, osConfig, ... }:
let
  inherit (osConfig.systemProfile) palette;

  # A palette color ("#RRGGBB") at an opacity, as CSS rgba().
  rgba = role: opacity:
    let
      channel = start: toString (lib.fromHexString (builtins.substring start 2 palette.${role}));
    in
    "rgba(${channel 1}, ${channel 3}, ${channel 5}, ${opacity})";
in
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    programs.hyprshell = {
      enable = true;
      package = pkgs.hyprshell;
      systemd.target = "graphical-session.target";
      systemd.args = "--config-file ${config.xdg.configHome}/hyprshell/config.json";
      settings = {
        windows = {
          enable = true;
          switch = {
            enable = true;
            modifier = "alt";
          };
        };
      };

      # The switcher in the theme's colors. hyprshell uses these variables
      # everywhere; the rest of its default styles stay.
      styleFile = ''
        :root {
          --border-color: ${rgba "border" "1"};
          --border-color-active: ${rgba "accent" "1"};

          --bg-color: ${rgba "bg" "0.9"};
          --bg-color-hover: ${rgba "elevated" "1"};
          --bg-window-color: ${rgba "surface" "0.95"};
          --popover-bg-color: ${rgba "overlay" "1"};

          --text-color: ${rgba "fg" "1"};
        }
      '';
    };

    systemd.user.services.hyprshell.Unit = {
      ConditionEnvironment = "HYPRLAND_INSTANCE_SIGNATURE";
      X-Restart-Triggers = [
        config.xdg.configFile."hyprshell/config.json".source
        config.xdg.configFile."hyprshell/styles.css".source
      ];
    };
  };
}
