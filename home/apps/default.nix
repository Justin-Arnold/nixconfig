{ lib, pkgs, config, ... }:
{
  imports = [
    ../alacritty.nix
    ../zsh.nix
    ../hello.nix
    ../neovim.nix
  ];
}