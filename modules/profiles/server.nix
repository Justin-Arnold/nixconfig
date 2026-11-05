{ pkgs, config, lib, sops-nix, ... }:
let
  cfg = config.profiles.server;
in
{
  options.profiles.server = {
    platform = lib.mkOption {
      type = lib.types.enum [ "proxmox" "cloud" ];
      default = "proxmox";
      description = ''
        Where the server runs. "proxmox" keeps the Proxmox VM defaults
        (GRUB on /dev/vda, qemu guest agent, cloud-init). "cloud" leaves boot
        devices to disko and does not run cloud-init or the guest agent.
      '';
    };

    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        # Mac Mini
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com"
        # Terraform Controller
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKTJF6UBOrXQSdBKJqcVdkaLYikLfj6Su+YQ0eXII9vq tf-controller"
        # Ansible Controller
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHV8PNnNJ9KwJfGC1+Z5AFPPMgW+Vjr0/eHOLg2WIofh ansible-controller"
      ];
      description = "SSH public keys allowed to log in as the server user.";
    };

    autoUpgrade.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the nightly system.autoUpgrade (with reboot).";
    };
  };

  config = lib.mkMerge [
    {
      ############################################################
      ## Bootloader Configuration
      ############################################################
      # turn off systemd-boot/EFI
      boot.loader.systemd-boot.enable = lib.mkForce false;
      boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
      # enable GRUB for BIOS
      boot.loader.grub.enable = true;

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
        openssh.authorizedKeys.keys = cfg.authorizedKeys;
      };

      # nixos-anywhere --extra-files copies bootstrap files as root. The age key is
      # intentionally placed under the server user's home for sops-nix, so repair
      # ownership before Home Manager tries to link files under ~/.config.
      system.activationScripts.fixUserConfigOwnership.text = ''
        if [ -d /home/${config.systemProfile.username}/.config ]; then
          chown -R ${config.systemProfile.username}:users /home/${config.systemProfile.username}/.config
        fi
      '';

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
    }

    ############################################################
    ## Proxmox VM & Cloud-Init
    ############################################################
    (lib.mkIf (cfg.platform == "proxmox") {
      boot.loader.grub.devices = [ "/dev/vda" ];
      services.qemuGuest.enable = true;
      services.cloud-init.enable = true;
    })

    ############################################################
    ## Auto Upgrades
    ############################################################
    (lib.mkIf cfg.autoUpgrade.enable {
      system.autoUpgrade = {
        enable = true;
        allowReboot = true;
        dates = "03:30";
      };
    })
  ];
}
