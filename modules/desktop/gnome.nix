{ config, pkgs, ... }:

{
  services.xserver = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
  };

  # Set the default session to GNOME
  services.xserver.displayManager.defaultSession = "gnome";

  # Enable auto-login for GNOME
  services.xserver.displayManager.autoLogin = {
    enable = true;
    user = "justin";
  };
}
