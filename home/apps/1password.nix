{ pkgs,osConfig, lib, ... }:
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    home.packages = [
      pkgs._1password-gui
    ];
  };
}