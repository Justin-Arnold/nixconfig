{ lib, pkgs, osConfig, inputs, zen-browser, ... }:
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
    #./1password.nix
    ./obsidian.nix
    ./pnpm.nix
    ./slack.nix
    ./lazygit.nix
    ./utm.nix
    ./vscode.nix
    ./zen-browser.nix
    ./zsh.nix
  ];

  home.packages = with pkgs; [
    cargo
    rustc
    gcc
  ];
}
