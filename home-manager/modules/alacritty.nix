{ pkgs, ... }:

{
  # programs.alacritty.enable = true;
  home.packages = [
    pkgs.alacritty
  ];
  
  home.file = {
    ".config/alacritty/alacritty.toml".source = ../dotfiles/alacritty/alacritty.toml;
  };
}
