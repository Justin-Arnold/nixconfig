{ lib, zen-browser, osConfig, ...}:
{
  imports = [
    zen-browser.homeModules.twilight
  ];

  config = lib.mkIf osConfig.systemProfile.hasGui {

    programs.zen-browser = {
      enable = true;
    };
  };
}