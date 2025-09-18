{ lib, pkgs, osConfig, zen-browser, ... }:
{
  imports = [
    ../apps
  ];

  home.username = osConfig.systemProfile.username;
  home.homeDirectory = osConfig.systemProfile.homeDirectory;
  home.stateVersion = osConfig.systemProfile.stateVersion;

  programs.home-manager.enable = lib.mkDefault true;

  programs.git = {
    enable = true;
    userName = "Justin Arnold";
    userEmail = osConfig.systemProfile.email;
  };

  programs.direnv.enable = true;
}