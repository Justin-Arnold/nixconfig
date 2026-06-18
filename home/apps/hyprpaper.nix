{ pkgs, lib, osConfig, ... }:

{
  home.packages = [
    pkgs.hyprpaper
  ];

  services.hyprpaper = {
    enable = true;
    settings = {
      splash = false;
      preload = [ "/home/justin/Downloads/wallpaper.png" ];
      wallpaper = [ ",/home/justin/Downloads/wallpaper.png" ];
    };
  };
}
