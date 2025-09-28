{ lib, pkgs, osConfig, zen-browser, ... }: {
  imports = [
    ../apps/krusader.nix
    ../apps/anyrun.nix
    ../apps/hyprpaper.nix
    ../apps/hyprpanel.nix
  ];

  home.packages = with pkgs; [ luarocks unzip ];

  home.file = {
    ".config/hypr/hyprland.conf".source = ../dotfiles/hyprland/hyprland.conf;
    ".config/hypr/hyprpaper.conf".source = ../dotfiles/hyprland/hyprpaper.conf;
  };

  programs.ssh = {
    enable = true;
    extraConfig = ''
      Host *
          IdentityAgent ~/.1password/agent.sock
    '';
  };
}
