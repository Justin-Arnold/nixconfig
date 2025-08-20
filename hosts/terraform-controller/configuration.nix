{ config, pkgs, lib, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/profiles/base.nix
      ../../modules/profiles/server.nix
      ../../modules/roles/terraform.nix
      ../../modules/platforms/nixos.nix
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
  boot.loader.grub.devices = [ "/dev/vda" ];  # virtio disk in your VM
}
