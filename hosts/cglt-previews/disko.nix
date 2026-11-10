# Two disks (infra/terranix/hosts/cglt-previews.nix):
#   - scsi0, 500 GB on proxmox4's local ZFS: swap, an 80 GB ext4 root that
#     holds Docker (images, build cache, the ops tools' state), and the rest as
#     the ZFS pool `tank` for what open PRs use: cached copies and clones.
#   - scsi1, 1 TB on the NAS: the pool `cold`, the golden copies of every
#     instance.
#
# Only the pools are made here, at install. Their datasets come from
# preview-datasets.service and preview-cold-pool.service (configuration.nix),
# and the second service also makes `cold` on a host installed before it
# existed, so a pool made either way gets the same.
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

    disk.cold = {
      device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";
      type = "disk";
      content = {
        type = "zfs";
        pool = "cold";
      };
    };
    zpool.cold = {
      type = "zpool";
      # The same options preview-cold-pool.service uses (configuration.nix).
      options = {
        ashift = "12";
        autotrim = "on";
        # NFS under the disk can stall; fail the I/O instead of hanging every
        # zfs command on the host.
        failmode = "continue";
      };
      rootFsOptions = {
        compression = "zstd";
        atime = "off";
        xattr = "sa";
        dnodesize = "auto";
        acltype = "posixacl";
        # Everything here can be copied again, and it's written in bulk.
        sync = "disabled";
        # Read sequentially (zfs send to the cache), so keep the ARC for tank.
        primarycache = "metadata";
        mountpoint = "none";
        canmount = "off";
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
