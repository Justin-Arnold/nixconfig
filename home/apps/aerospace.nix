{pkgs, ... }:
{
  config = lib.mkIf osConfig.systemProfile.isDarwin {
    home.packages = [
      pkgs.aerospace
    ];

    home.file.".aerospace.toml".source = ../dotfiles/aerospace/aerospace.toml;
  }
}