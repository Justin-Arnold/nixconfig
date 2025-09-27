{ pkgs, osConfig, lib, inputs, ... }:
{
  config = lib.mkIf osConfig.systemProfile.hasGui {

    home.packages = [
      pkgs._1password-gui
    ];

    programs._1password-shell-plugins = {
      enable = true;
      plugins = [ 
        pkgs.gh
      ];
    };
  };
}
