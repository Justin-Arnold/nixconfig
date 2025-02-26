{ config, pkgs, self, zen-browser, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/desktop
    ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nixos";
  networking.networkmanager.enable = true;

  time.timeZone = "America/New_York";

  i18n.defaultLocale = "en_US.UTF-8";

  services.xserver = {
    enable = true;
    xkb = {
      layout = "us";
      variant = "";
    };
  };

  services.printing.enable = true;
  environment.systemPackages =  [
    zen-browser.packages."x86_64-linux".default
  ];
  hardware.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  services.libinput.touchpad.naturalScrolling = true;

  programs.firefox.enable = true;

  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
 
  services.xserver.videoDrivers = [ "intel" ];
  services.xserver.deviceSection = ''
    Option "DRI" "2"
    Option "TearFree" "true"
  '';  

   system.stateVersion = "24.05";
}
