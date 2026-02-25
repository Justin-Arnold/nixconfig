{ ... }:

# disko disk layout for monitoring-vm
# Device: /dev/sda (VirtIO SCSI, 64 GiB)
# Scheme: GPT + BIOS boot stub + single ext4 root
#
# Applied automatically by nix-anywhere before NixOS installation.
# Run `nix run .#monitoring-vm-deploy` — disko is invoked under the hood.
{
  disko.devices = {
    disk = {
      sda = {
        type   = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            # 1 MiB BIOS boot stub required by GRUB on GPT+BIOS systems.
            boot = {
              size = "1M";
              type = "EF02";
            };
            # Remainder of disk is the root filesystem.
            root = {
              size    = "100%";
              content = {
                type       = "filesystem";
                format     = "ext4";
                mountpoint = "/";
                mountOptions = [ "defaults" ];
              };
            };
          };
        };
      };
    };
  };
}
