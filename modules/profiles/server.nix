{ pkgs, config, lib, sops-nix, ... }:
{
  config = lib.mkIf config.systemProfile.isServer {
    ############################################################
    ## Bootloader Configuration
    ############################################################
    # turn off systemd-boot/EFI
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
    # enable GRUB for BIOS
    boot.loader.grub.enable = true;
    boot.loader.grub.devices = [ "/dev/vda" ];

    ############################################################
    ## Network Configuration
    ############################################################
    networking.firewall.enable = true;
    networking.firewall.allowedTCPPorts = [
      22 # SSH
    ];
    networking.useNetworkd = true; 

    ############################################################
    ## User Configuration
    ############################################################
    users.users."${config.systemProfile.username}" = {
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [
        # Mac Mini
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com"
        # Terraform Controller
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKTJF6UBOrXQSdBKJqcVdkaLYikLfj6Su+YQ0eXII9vq tf-controller"
        # Ansible Controller
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHV8PNnNJ9KwJfGC1+Z5AFPPMgW+Vjr0/eHOLg2WIofh ansible-controller"
      ];
    };
    security.sudo.wheelNeedsPassword = false;

    ############################################################
    ## Nix
    ############################################################
    nix.settings.trusted-users = [
      "${config.systemProfile.username}"
    ];

    ############################################################
    ## System Packages
    ############################################################
    environment.systemPackages = with pkgs; [
      curl    # for fetching resources
      wget    # for downloading files
      htop    # for system monitoring
      jq      # for JSON processing
      ripgrep # for searching text
      fd      # for finding files
      lsof    # for listing open files
      python3  # for running Python scripts
    ];

    ############################################################
    ## SSH
    ############################################################
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
      };
    };

    ############################################################
    ## Proxmox VM & Cloud-Init
    ############################################################
    services.qemuGuest.enable = true;
    services.cloud-init.enable = true;

    ############################################################
    ## Auto Upgrades
    ############################################################
    system.autoUpgrade = {
      enable = true;
      allowReboot = true;
      dates = "03:30";
    };
  };
  # system.autoUpgrade.flake = "/etc/nixos#hostname"; # Local flake
  # or
  # system.autoUpgrade.flake = "github:your-user/your-flake#hostname"; # Remote flake
}