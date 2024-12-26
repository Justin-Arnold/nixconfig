{ pkgs, ... }:

{
  # programs.alacritty.enable = true;
  home.packages = [
    pkgs.yarn
  ];
}
