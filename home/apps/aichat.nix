# home.nix
{ config, pkgs, ... }:

{
  home.packages = with pkgs; [ aichat ];

  # Create the popup script
  home.file.".local/bin/aichat-popup" = {
    text = ''
      #!/usr/bin/env bash
      alacritty --class aichat-popup -e aichat
    '';
    executable = true;
  };
}
