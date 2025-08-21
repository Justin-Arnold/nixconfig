{ lib, pkgs, config, ... }:
{
  imports = [
    ../../apps
  ];

  home.username = lib.mkDefault "justin";
  home.homeDirectory = lib.mkDefault (
    if pkgs.stdenv.hostPlatform.isDarwin
      then "/Users/${config.home.username}"
      else "/home/${config.home.username}"
  );

  programs.home-manager.enable = lib.mkDefault true;

  programs.git = {
    enable = true;
    userName = "Justin Arnold";
    userEmail = "hello@justin-arnold.com";
  };
}