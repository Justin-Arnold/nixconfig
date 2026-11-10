{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "cglt-previews";
  # Not HA by choice (2026-11-09): local proxmox4 storage and cpuType host
  # for ZFS/build speed. If stability is lacking, add HA (nas-shared +
  # x86-64-v2-AES) or move to a cloud provider. See
  # docs/cglt-previews/REFERENCE.md, "Where it runs".
  proxmoxNode = "proxmox4";
  # A fixed id that had never been used (145), for the reason in
  # automation.nix.
  vmId = 145;
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:0b";
  # Two runners building images and up to 12 previews (PHP and MySQL each).
  cpuCores = 12;
  # It never migrates, so builds get every CPU feature the node has.
  cpuType = "host";
  memoryMb = 49152;
  # 80 GB ext4 root (Docker's images and build cache) and the rest the
  # guest's ZFS pool for golden copies and preview clones
  # (hosts/cglt-previews/disko.nix).
  diskSizeGb = 500;
  # proxmox4's local-lvm thin pool was already promised more than its 816 GB
  # when this host was made; zfs-pool had 2.4 TB free. A full thin pool
  # pauses every VM on it, so the big disk goes on ZFS, and the cloud-init
  # drive with it.
  datastore = "zfs-pool";
  cloudInitDatastore = "zfs-pool";
  # Previews are copies of instances that can be pulled again, and golden
  # snapshots are rebuilt nightly, so no backup job should copy 500 GB of it.
  diskBackup = false;
  # The golden copies of every instance live on the NAS, not on proxmox4's
  # fast disk, which only holds what open PRs use (2026-11-10). 1 TB on
  # `nas-previews`: a TrueNAS dataset of its own (Main/cglt-previews) with no
  # snapshots or replication, since everything on it can be copied again.
  # The guest makes the ZFS pool `cold` on it (preview-cold-pool.service).
  # docs/cglt-previews/REFERENCE.md, "Storage".
  extraDisks = [
    {
      datastore = "nas-previews";
      interface = "scsi1";
      sizeGb = 1024;
      backup = false;
    }
  ];
  tags = [ "homelab" "cglt" "preview" ];
}
