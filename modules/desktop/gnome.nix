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

  # Workaround for GNOME autologin: https://github.com/NixOS/nixpkgs/issues/103746#issuecomment-945091229
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;


}
