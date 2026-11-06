{ pkgs, lib, config, ... }:

let
  cfg = config.modules.apps.flatpak;
  applications = lib.unique cfg.applications;
in {
  options.modules.apps.flatpak = {
    enable = lib.mkEnableOption "Flatpak support";

    applications = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Flatpak application IDs to install from Flathub.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.flatpak.enable = true;
    xdg.portal.enable = true;

    systemd.services.flatpak-applications = lib.mkIf (applications != []) {
      description = "Install configured Flatpak applications";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      path = [
        pkgs.coreutils
        pkgs.flatpak
        pkgs.gnugrep
      ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      script = ''
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

        for app in ${lib.escapeShellArgs applications}; do
          if flatpak info --system "$app" >/dev/null 2>&1; then
            flatpak update --system --noninteractive "$app"
          else
            flatpak install --system --noninteractive flathub "$app"
          fi
        done
      '';
    };
  };
}
