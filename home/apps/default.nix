{ lib, pkgs, osConfig, ... }:
{
  imports = [
    ./alacritty.nix
    ./zsh.nix
    ./hello.nix
    ./neovim.nix
  ];
}