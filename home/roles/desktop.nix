{ lib, pkgs, osConfig, ... }:
{
  imports = [
    ../apps/1password.nix
    ../apps/discord.nix
  ];
}