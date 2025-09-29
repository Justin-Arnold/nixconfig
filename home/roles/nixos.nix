{ lib, pkgs, osConfig, zen-browser, ... }: {
  imports = [ ../apps/krusader.nix ../apps/anyrun.nix ../apps/aichat.nix ];

  home.packages = with pkgs; [ luarocks unzip ];

  programs.ssh = {
    enable = true;
    extraConfig = ''
      Host *
          IdentityAgent ~/.1password/agent.sock
    '';
  };
}
