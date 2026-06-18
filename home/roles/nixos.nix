{ lib, pkgs, osConfig, zen-browser, ... }: {
  imports = [
    ../apps/oterm.nix
    ../apps/krusader.nix
    ../apps/anyrun.nix
    ../apps/aichat.nix
  ];

  home.packages = with pkgs; [ luarocks unzip ];

  programs.ssh = {
    enable = true;
    extraConfig = ''
      Host *
          IdentityAgent ~/.1password/agent.sock
    '';
  };

  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = 1;
  };

  qt = {
    enable = true;
    style = {
      name = "adwaita-dark";
    };
  };
}
