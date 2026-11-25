# https://wayle.app/guide/getting-started-nixos

{ config, inputs, lib, osConfig, pkgs, ... }:
let
  fontFamily = osConfig.systemProfile.fonts.primary.family;
  inherit (osConfig.systemProfile) theme palette;
  wayle = lib.getExe' config.services.wayle.package "wayle";
  tomlFormat = pkgs.formats.toml { };

  # Wayle's ten color roles. Wayle has no setting that names a theme, so the
  # colors themselves go in the config. Gneiss has a Wayle theme of its own,
  # in the gneiss input; the other themes map their palette's roles here.
  waylePalette =
    if theme == "gneiss" then inputs.gneiss.lib.wayle.palette
    else {
      inherit (palette) bg surface elevated fg fg-muted red yellow green blue;
      primary = palette.accent;
    };

  # Settings declared here that Wayle's settings panel or CLI can override
  # in runtime.toml. Wayle can't reset a whole table, so each color is
  # listed.
  overridable = [
    "general.font-sans"
    "general.font-mono"
    "styling.theme-provider"
  ] ++ map (role: "styling.palette.${role}") (lib.attrNames waylePalette);
in
{
  # Wayle gives runtime settings priority over the Home Manager config, so a
  # config change clears the overrides of what's declared here. A theme
  # picked in Wayle's settings lasts until then; `wayle config reset` with
  # one of these paths clears it sooner.
  xdg.configFile."wayle/config.toml".onChange = ''
    if [[ -f ${lib.escapeShellArg "${config.xdg.configHome}/wayle/runtime.toml"} ]]; then
      for path in ${lib.escapeShellArgs overridable}; do
        XDG_CONFIG_HOME=${lib.escapeShellArg config.xdg.configHome} ${wayle} config reset "$path" >/dev/null
      done
    fi
  '';

  # The same colors as a Wayle theme file, so the theme is also listed in
  # Wayle's settings: Gneiss's own file, or one made here. Wayle has Nord
  # built in, and skips a file named after a built-in.
  xdg.configFile."wayle/themes/${theme}.toml" = lib.mkIf (theme != "nord") {
    source =
      if theme == "gneiss" then inputs.gneiss.packages.${pkgs.stdenv.hostPlatform.system}.wayle
      else tomlFormat.generate "wayle-theme-${theme}.toml"
        # Theme files spell this one with an underscore; the config, with a
        # hyphen.
        (lib.removeAttrs waylePalette [ "fg-muted" ] // { fg_muted = waylePalette.fg-muted; });
  };

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

    # Whether to automatically install soft dependencies used by wayle that
    # will be required based on your config.
    autoInstallDependencies = true;

    settings = {
      general = {
        font-sans = fontFamily;
        font-mono = fontFamily;
      };

      styling = {
        # Static colors. The other providers (matugen, pywal, wallust) take
        # them from the wallpaper instead, and can recolor the terminals too.
        theme-provider = "wayle";
        palette = waylePalette;
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
