{ pkgs, ... }:
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    home.packages = [
      pkgs._1password-gui
    ];
  };
}