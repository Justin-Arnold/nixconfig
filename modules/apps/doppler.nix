{ pkgs, lib, config, ... }:

let
  cfg = config.modules.apps.doppler;
in
{
  options.modules.apps.doppler = {
    enable = lib.mkEnableOption "Doppler CLI";
  };

  config = lib.mkMerge [
    {
      modules.apps.doppler.enable = lib.mkDefault config.systemProfile.forCglt;
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ pkgs.doppler ];
    })
  ];
}
