{ config, pkgs, self, home-manager, sops-nix, zen-browser, inputs, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      home-manager.nixosModules.home-manager
    ];

  ############################################################
  ## System Profile
  ############################################################
  systemProfile = {
    hostname = "desktop";
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
  # services.displayManager.cosmic-greeter.enable = true;
  # services.desktopManager.cosmic.enable = true;
  #services.xserver.enable = true;
  #services.xserver.displayManager.gdm.enable = true;
  #services.xserver.desktopManager.gnome.enable = true;
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
  ## Steam
  ##############################################################
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
  };

  ##############################################################
  ## Home Manager Configuration
  ##############################################################
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";
  home-manager.extraSpecialArgs = { inherit inputs zen-browser; };
  home-manager.sharedModules = [
    sops-nix.homeManagerModules.sops
    inputs._1password-shell-plugins.hmModules.default
  ];
  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
      ../../home/roles/nixos.nix
      ../../home/roles/provisioning-runner.nix
    ];
  };
}
