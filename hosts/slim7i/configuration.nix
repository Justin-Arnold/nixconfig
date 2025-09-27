{ config, lib, pkgs, self, zen-browser, home-manager, inputs, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/platforms/nixos
      ../../modules/profiles/desktop.nix
    ];
  
  boot.kernelModules = [ "uinput" ];
  hardware.uinput.enable = true;
  services.udev.extraRules = ''
    KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
  '';
  users.groups.uinput = { };
  systemd.services.kanata-internalKeyboard.serviceConfig = {
    SupplementaryGroups = [
      "input"
      "uinput"
    ];
  };
  services.kanata = {
    enable = true;
    keyboards = {
      internalKeyboard = {
        devices = [
	  "/dev/input/by-path/platform-i8042-serio-0-event-kbd"
        ];
        extraDefCfg = "process-unmapped-keys yes";
        config = ''
          (defsrc
            lalt lmet
          )
          (defalias
            ;; Swap Super and Left Alt
            swapped-alt lmet    ;; Left Alt becomes Super/Windows key
            swapped-super lalt  ;; Super becomes Left Alt
          )
          (deflayer base
            @swapped-alt @swapped-super
          )
        '';    
      };
    };
  };
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
  
  services.logind.settings.Login.HandlePowerKey = "ignore";

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
  services.libinput.touchpad.naturalScrolling = true;
  services.libinput.touchpad.tapping  = true;

  services.xserver.xkb.options = "altwin:swap_lalt_lwin";
  services.libinput.touchpad.tappingButtonMap = "lrm";
  ##############################################################
  ## Home Manager Configuration
  ##############################################################
  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}
