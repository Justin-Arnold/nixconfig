{ config, pkgs, self, zen-browser, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/desktop
    ];

     # slim7i = makeNixos [] {
        #   system = "x86_64-linux";
        #   modules = [
        #     ./hosts/slim7i/configuration.nix
        #     # Add any additional modules here
        #     home-manager.nixosModules.home-manager
        #     {
        #       home-manager.useGlobalPkgs = true;
        #       home-manager.useUserPackages = true;
        #       home-manager.backupFileExtension = "backup";
        #       users.users.justin.home = "/home/justin";
        #       users.users.justin.isNormalUser = true;
        #       users.users.justin.group = "justin";
        #       users.groups.justin = {};
        #       home-manager.users.justin = import ./home-manager/home.nix;
        #     }
        #   ];
        #   specialArgs = { inherit self; inherit zen-browser;};
        # };

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
 
  services.xserver.videoDrivers = [ "modedriver" ];
  services.xserver.deviceSection = ''
    Option "DRI" "2"
    Option "TearFree" "true"
  '';  

   system.stateVersion = "24.05";
}
