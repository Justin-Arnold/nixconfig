# home.nix
{ config, pkgs, ... }:

{
  home.packages = with pkgs; [ oterm ];

  # Create the popup script
  home.file.".local/bin/oterm-popup" = {
    text = ''
      #!/usr/bin/env bash
      alacritty --class oterm-popup -e oterm
    '';
    executable = true;
  };
}
