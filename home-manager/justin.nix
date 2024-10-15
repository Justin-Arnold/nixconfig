{ config, pkgs, ... }:

{
  home.username = "justin";
  home.homeDirectory = "/home/justin";

  home.packages = with pkgs; [
    # Add any user-specific packages here
  ];

  programs.home-manager.enable = true;

  home.stateVersion = "24.05";
}
