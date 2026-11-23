{ config, pkgs, self, home-manager, sops-nix, zen-browser, inputs, ... }:

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
    hostname = "desktop";
    stateVersion = "24.05";
    hasGui = true;
    forCglt = true;
    # Trying Gneiss here before it becomes the default (docs/theming).
    theme = "gneiss";
  };

  ############################################################
  ## Boot Configuration
  ############################################################
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 5;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Claude Cowork uses the KVM support from hardware-configuration.nix.
  boot.kernelModules = [ "vhost_vsock" ];
  users.users.${config.systemProfile.username}.extraGroups = [ "kvm" ];
  # Claude probes these paths directly when preparing its QEMU guest.
  systemd.tmpfiles.rules = [
    "L+ /usr/share/OVMF/OVMF_CODE_4M.fd - - - - ${pkgs.OVMF.firmware}"
    "L+ /usr/share/OVMF/OVMF_VARS_4M.fd - - - - ${pkgs.OVMF.variables}"
    "L+ /usr/libexec/virtiofsd - - - - ${pkgs.virtiofsd}/bin/virtiofsd"
  ];

  ############################################################
  ## Networking
  ############################################################
  networking.networkmanager.enable = true;

  #############################################################
  ## GUI/Display Manager
  #############################################################
  services.displayManager.cosmic-greeter.enable = true;
  services.desktopManager.cosmic.enable = true;
  #services.xserver.enable = true;
  #services.xserver.displayManager.gdm.enable = true;
  #services.xserver.desktopManager.gnome.enable = true;
  ##############################################################
  ## Audio
  ##############################################################
  services.pulseaudio.enable = false;
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
    extraCompatPackages = [
      pkgs.proton-ge-bin
    ];
    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
    localNetworkGameTransfers.openFirewall = true; # Open ports in the firewall for Steam Local Network Game Transfers
  };

  ##############################################################
  ## Home Manager Configuration
  ##############################################################
  home-manager.users.justin = { ... }: {
    home.packages = [ pkgs.qemu_kvm ];
    imports = [ 
      ../../home/roles/provisioning-runner.nix
    ];
  };
}
