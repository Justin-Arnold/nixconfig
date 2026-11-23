{ lib, zen-browser, osConfig, ...}:
{
  imports = [
    zen-browser.homeModules.twilight
  ];

  config = lib.mkIf osConfig.systemProfile.hasGui {

    programs.zen-browser = {
      enable = true;

      # Glance is Zen's popout over the current tab: it opens on its own for
      # a link from a pinned or Essential tab to another site, and on
      # Alt + click. Off, links open as ordinary tabs.
      #
      # Through autoconfig, not policies.Preferences: Zen's policies only
      # take an allowlist of prefixes (browser., ui., ...) and reject zen.*.
      # Locked, so it can't be turned back on from Settings.
      extraPrefs = ''
        lockPref("zen.glance.enabled", false);
      '';
    };
  };
}