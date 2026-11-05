# Facts about the purchased Contabo Cloud VPS 12 (product V156, EU, monthly).
#
# Sources: Terraform outputs (`nix run .#plan`) and
# scripts/provisioning/inspect-cloud-host.sh run against the provider's stock
# image. BIOS firmware, virtio-scsi disk, static addressing with the IPv6
# gateway on-link. The host refuses to build while a required fact is null,
# so nothing gets installed on guessed values.
{
  contaboInstanceId = "203635567";

  # Interface is matched by MAC so predictable-name changes cannot break networking.
  macAddress = "00:50:56:68:03:34";

  ipv4 = {
    address = "89.117.73.89";
    prefixLength = 21;
    gateway = "89.117.72.1";
  };

  # Optional: leave address null to run IPv4-only.
  ipv6 = {
    address = "2605:a144:2363:5567::1";
    prefixLength = 64;
    gateway = "fe80::1";
  };

  # Stable path, e.g. /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0
  diskDevice = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";
}
