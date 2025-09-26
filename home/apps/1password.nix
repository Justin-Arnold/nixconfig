{ pkgs, osConfig, lib, ... }:
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    imports = [
      inputs._1password-shell-plugins.hmModules.default
    ]

    home.packages = [
      pkgs._1password-gui
    ];

    programs._1password-shell-plugins = {
      enable = true;
      plugins = [ 
        phgs.gh
      ];
    };
  };
}