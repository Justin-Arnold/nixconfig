{ pkgs, lib, config, ...}:{
  imports = [
    ../roles/slack.nix
  ];
  environment.systemPackages = with pkgs; [
    discord
    libsForQt5.qt5ct
    qt6Packages.qt6ct
    libsForQt5.qtstyleplugin-kvantum
    doublecmd
    grimblast
  ];

  qt = {
    enable = true;
    platformTheme = "gnome";
    style = "adwaita-dark";
  };
}