{ config, pkgs, lib, sops-nix, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/profiles/base.nix
      ../../modules/profiles/server.nix
      ../../modules/roles/terraform.nix
      ../../modules/platforms/nixos.nix
      sops-nix.nixosModules.sops
    ];

  networking.hostName = "terraform-controller";
  system.stateVersion = "25.05";

  ############################################################
  ## Bootloader Configuration
  ############################################################
  # turn off systemd-boot/EFI
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  # enable GRUB for BIOS
  boot.loader.grub.enable = true;
  boot.loader.grub.devices = [ "/dev/vda" ];

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";

  sops.secrets."proxmox.env" = {
    sopsFile = ../../secrets/proxmox.env;
    format   = "dotenv"; 
    mode = "0400";
    owner = "justin";
    path  = "/run/secrets/proxmox.env";
    neededForUsers = true; 
  };
}
