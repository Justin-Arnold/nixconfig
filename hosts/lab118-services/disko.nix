{ config, ... }:
let
  device = config.lab118.facts.diskDevice;
in
{
  # Hybrid BIOS + UEFI GRUB so the disk boots whichever firmware mode Contabo
  # uses. Kernels stay on the ext4 root; the ESP only holds GRUB's EFI image.
  disko.devices.disk.main = {
    device = if device == null then "/dev/disk/by-id/FILL-IN-FROM-INSPECTION" else device;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
        };

        esp = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot/efi";
            mountOptions = [ "umask=0077" ];
          };
        };

        swap = {
          size = "4G";
          content = {
            type = "swap";
            randomEncryption = false;
          };
        };

        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  boot.loader.efi.efiSysMountPoint = "/boot/efi";
}
