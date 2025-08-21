{ config, pkgs, self, home-manager, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
    ];

  ############################################################
  ## System Profile
  ############################################################
  systemProfile = {
    hostname = "slim7i";
    stateVersion = "24.05";
    hasGui = true;
  };

  ############################################################
  ## Boot Configuration
  ############################################################
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  ############################################################
  ## Networking
  ############################################################
  networking.networkmanager.enable = true;

  #############################################################
  ## GUI/Display Manager
  #############################################################
  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic.enable = true;

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
  services.libinput.touchpad.naturalScrolling = true;

  ##############################################################
  ## Home Manager Configuration
  ##############################################################
  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}
