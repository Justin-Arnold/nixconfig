{ pkgs, lib, config, ... }:

let cfg = config.modules.apps.bluebubbles;
in {
  options.modules.apps.bluebubbles = {
    enable = lib.mkEnableOption "BlueBubbles desktop client";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.bluebubbles ];
  };
}
