{ lib, pkgs, inputs, osConfig, zen-browser, ... }:
{
  imports = [
    ../apps
  ];

  home.username = osConfig.systemProfile.username;
  home.homeDirectory = lib.mkForce (/. + osConfig.systemProfile.homeDirectory);
  home.stateVersion = "26.05";

  programs.home-manager.enable = lib.mkDefault true;

  programs.git = {
    enable = true;
    settings.user = {
      name = "Justin Arnold";
      email = osConfig.systemProfile.email;
    };
  };

  programs.direnv.enable = true;
}
