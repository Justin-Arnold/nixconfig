{ config, lib, pkgs, self, zen-browser, home-manager, inputs, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/platforms/nixos
      ../../modules/profiles/desktop.nix
    ];
  ############################################################
  ## System Profile
  ############################################################
  systemProfile = {
    hostname = "mac-parallels";
    stateVersion = "25.05";
    hasGui = true;
  };

  ############################################################
  ## Boot Configuration
  ############################################################
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  ############################################################
  ## Networking
  ############################################################
  networking.networkmanager.enable = true;

  #############################################################
  ## GUI/Display Manager
  #############################################################
  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic.enable = true;

  programs.hyprland = {
    enable = true;
    withUWSM = true; # recommended for most users
    xwayland.enable = true; # Xwayland can be disabled.
  };
  ##############################################################
  ## Audio
  ##############################################################
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  ##############################################################
  ## Trackpad
  ##############################################################
  # services.libinput.touchpad.naturalScrolling = true;
  # services.libinput.touchpad.tapping  = true;

  # services.xserver.xkb.options = "altwin:swap_lalt_lwin";
  # services.libinput.touchpad.tappingButtonMap = "lrm";
  ##############################################################
  ## Home Manager Configuration
  ##############################################################
  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}
