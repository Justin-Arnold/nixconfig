{ pkgs, ... }:

{
  home.packages = with pkgs; [ codex ];

  home.file.".local/bin/codex-popup" = {
    text = ''
      #!/usr/bin/env bash
      alacritty --class codex-popup -e codex
    '';
    executable = true;
  };
}
