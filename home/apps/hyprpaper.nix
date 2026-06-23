{ pkgs, osConfig, ... }:

let
  wallpaper = "${osConfig.systemProfile.homeDirectory}/Pictures/wallpaper.png";
in {
  home.packages = [
    pkgs.hyprpaper
  ];

  services.hyprpaper = {
    enable = true;
    settings = {
      preload = [
        wallpaper
      ];
      wallpaper = [
        {
          monitor = "";
          path = wallpaper;
        }
      ];
    };
  };
}
