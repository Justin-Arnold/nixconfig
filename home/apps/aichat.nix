# home.nix
{ config, pkgs, ... }:

{
  home.packages = [
    (pkgs.aichat.overrideAttrs (oldAttrs: {
      # nixpkgs' Rust setup hook requires onig_sys to use the system library,
      # but aichat 0.30.0 does not declare it.
      buildInputs = (oldAttrs.buildInputs or [ ]) ++ [ pkgs.oniguruma ];
    }))
  ];

  # Create the popup script
  home.file.".local/bin/aichat-popup" = {
    text = ''
      #!/usr/bin/env bash
      alacritty --class aichat-popup -e aichat
    '';
    executable = true;
  };
}
