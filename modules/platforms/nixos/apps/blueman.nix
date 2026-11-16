{ lib, config, ... }:

let
  cfg = config.modules.apps.blueman;
in {
  options.modules.apps.blueman = {
    enable = lib.mkEnableOption "Blueman Bluetooth management";
  };

  config = lib.mkIf cfg.enable {
    hardware.bluetooth = {
      enable = true;
      powerOnBoot = true;
    };

    services.blueman.enable = true;
  };
}
