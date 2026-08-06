{ lib, config, ... }:

let cfg = config.modules.apps.greenlight;
in {
  options.modules.apps.greenlight = {
    enable = lib.mkEnableOption "Greenlight xCloud and Xbox home streaming client";

    flatpakRef = lib.mkOption {
      type = lib.types.str;
      default = "io.github.unknownskl.greenlight";
      description = "Flatpak application ID for Greenlight.";
    };
  };

  config = lib.mkIf cfg.enable {
    modules.apps.flatpak = {
      enable = true;
      applications = [ cfg.flatpakRef ];
    };
  };
}
