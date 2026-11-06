{ lib, config, ... }:

let cfg = config.modules.apps.openbubbles;
in {
  options.modules.apps.openbubbles = {
    enable = lib.mkEnableOption "OpenBubbles desktop client";

    flatpakRef = lib.mkOption {
      type = lib.types.str;
      default = "app.openbubbles.OpenBubbles";
      description = "Flatpak application ID for OpenBubbles.";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.apps.flatpak = {
      enable = true;
      applications = [ cfg.flatpakRef ];
    };
  };
}
