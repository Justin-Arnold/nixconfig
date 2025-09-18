{ lib, zen-browser, ...}:
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    imports = [
      zen-browser.homeModules.twilight
    ];

    programs.zen-browser = {
      enable = true;
    };
  };
}