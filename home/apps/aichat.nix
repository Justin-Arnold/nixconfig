# home.nix
{ config, pkgs, ... }:

{
  home.packages = with pkgs; [ aichat kitty ];

  # Create the popup script
  home.file.".local/bin/aichat-popup" = {
    text = ''
      #!/usr/bin/env bash
      kitty --class aichat-popup -e aichat
    '';
    executable = true;
  };

  wayland.windowManager.hyprland = {
    enable = true;
    settings = {
      windowrulev2 = [
        "float,class:^(aichat-popup)$"
        "size 800 600,class:^(aichat-popup)$"
        "center,class:^(aichat-popup)$"
        "animation slide,class:^(aichat-popup)$"
      ];

      bind = [ "SUPER_SHIFT, Space, exec, ~/.local/bin/aichat-popup" ];
    };
  };
}
