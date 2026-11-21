{ config, pkgs, lib, osConfig, ... }:

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
    };

    systemd.user.services.hyprshell.Unit = {
      ConditionEnvironment = "HYPRLAND_INSTANCE_SIGNATURE";
      X-Restart-Triggers = [ config.xdg.configFile."hyprshell/config.json".source ];
    };
  };
}
