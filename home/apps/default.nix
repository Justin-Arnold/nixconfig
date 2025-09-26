{ lib, pkgs, osConfig, zen-browser, ... }:
{
  imports = [
    ./aerospace.nix
    ./alacritty.nix
    ./bun.nix
    ./discord.nix
    ./github.nix
    ./gitkraken.nix
    ./hello.nix
    ./neovim.nix
    ./obsidian.nix
    ./pnpm.nix
    ./slack.nix
    ./utm.nix
    ./vscode.nix
    ./zen-browser.nix
    ./zsh.nix
  ];
}