{ pkgs, lib, osConfig, ... }:

{
  home.packages = [
    pkgs.hyprpaper
  ];

  home.file = {
    ".config/hypr/hyprpaper.conf".source = ../dotfiles/hyprland/hyprpaper.conf;
  };
}
