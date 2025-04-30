{pkgs, ... }: {
  home.packages = [
    pkgs.aerospace
  ];

  home.file.".aerospace.toml".source = ../dotfiles/aerospace/aerospace.toml;
}