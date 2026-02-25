{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [
    "ata_piix" "uhci_hcd" "virtio_pci" "sr_mod" "virtio_blk"
  ];
  boot.initrd.kernelModules  = [ ];
  boot.kernelModules         = [ ];
  boot.extraModulePackages   = [ ];

  # Filesystem layout is declared in disk-config.nix (disko).
  # disko sets fileSystems automatically; nothing to add here.

  # DHCP for all interfaces — server.nix enables useNetworkd;
  # this default ensures systemd-networkd picks up every NIC.
  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
