# One 500 GB disk (infra/terranix/hosts/cglt-previews.nix): swap, an 80 GB
# ext4 root that holds Docker (images, build cache, the ops tools' state), and
# the rest as the ZFS pool `tank` for golden copies and preview clones.
#
# Only the pool is made here. Its datasets come from preview-datasets.service
# (configuration.nix), so a pool made some other way gets them too.
{ ... }:
{
  disko.devices = {
    disk.main = {
      device = "/dev/sda";
      type = "disk";
      content = {
        type = "gpt";
        partitions = {
          bios = {
            size = "1M";
            type = "EF02";
          };

          swap = {
            size = "8G";
            content = {
              type = "swap";
              randomEncryption = false;
            };
          };

          root = {
            size = "80G";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };

          tank = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "tank";
            };
          };
        };
      };
    };

    zpool.tank = {
      type = "zpool";
      options = {
        ashift = "12";
        autotrim = "on";
      };
      # Inherited by every dataset. The pool's own dataset holds nothing and
      # isn't mounted.
      rootFsOptions = {
        compression = "zstd";
        atime = "off";
        xattr = "sa";
        dnodesize = "auto";
        acltype = "posixacl";
        mountpoint = "none";
        canmount = "off";
      };
    };
  };
}
