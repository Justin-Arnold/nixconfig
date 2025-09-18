{ lib, pkgs, osConfig, zen-browser, ... }:
{
  imports = [
    ./alacritty.nix
    ./zsh.nix
    ./hello.nix
    ./neovim.nix
    ./vscode.nix
    ./obsidian.nix
    ./slack.nix
    ./gitkraken.nix
    ./bun.nix
    ./pnpm.nix
    ./discord.nix
    ./aerospace.nix
    ./zen-browser.nix
  ];
}