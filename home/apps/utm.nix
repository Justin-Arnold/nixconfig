{ pkgs, lib, osConfig, ... }:

{
  config = lib.mkIf osConfig.systemProfile.isDarwin {
    home.packages = [
      pkgs.utm
    ];
  };
}
