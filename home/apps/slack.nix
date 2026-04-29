{ pkgs, lib, osConfig, ... }:

{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    home.packages = [
      pkgs.slack
    ];
  };
}
