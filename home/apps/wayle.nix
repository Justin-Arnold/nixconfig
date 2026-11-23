# Wayle took over from hyprpanel when nixpkgs archived it in November 2026.
# It's a whole shell: the bar, notifications, on-screen display and the
# dashboard menu. `wayle panel settings` changes things live, and writes them
# to ~/.config/wayle/runtime.toml, not here; copy anything worth keeping back
# into settings below.
{ config, lib, osConfig, pkgs, ... }:
let
  fontFamily = osConfig.systemProfile.fonts.primary.family;
  wayle = lib.getExe' config.services.wayle.package "wayle";
in
{
  # Wayle gives runtime settings priority over the Home Manager config.
  xdg.configFile."wayle/config.toml".onChange = ''
    if [[ -f ${lib.escapeShellArg "${config.xdg.configHome}/wayle/runtime.toml"} ]]; then
      XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome} ${wayle} config reset general.font-sans
      XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome} ${wayle} config reset general.font-mono
    fi
  '';

  # Reload the font map when the installed primary font changes.
  systemd.user.services.wayle.Unit.X-Restart-Triggers = [
    osConfig.systemProfile.fonts.primary.package
  ];

  services.wayle = {
    enable = true;

    package = pkgs.wayle.overrideAttrs (oldAttrs: {
      # Wayle's SQLite-backed modules link libsqlite3, which is missing from
      # the nixpkgs 0.7.1 package inputs.
      buildInputs = (oldAttrs.buildInputs or [ ]) ++ [ pkgs.sqlite ];
    });

    settings = {
      general = {
        font-sans = fontFamily;
        font-mono = fontFamily;
      };

      bar = {
        background-opacity = 0;
        layout = [
          {
            monitor = "*";
            left = [ "dashboard" "hyprland-workspaces" ];
            center = [ "media" ];
            right = [ "volume" "systray" "notifications" ];
          }
        ];
      };

      modules.hyprland-workspaces.app-icons-show = true;

      # Wayle's default, `loginctl terminate-session $XDG_SESSION_ID`, does
      # nothing here: Wayle runs as a user service, which has no
      # XDG_SESSION_ID. The session is run by UWSM (see
      # desktopEnvironments/hyprland.nix), so ask it to stop.
      modules.dashboard.dropdown-logout-command = "uwsm stop";
    };
  };
}
