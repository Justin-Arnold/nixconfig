{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "workbench";
  # It stays here: the disk is on this node's local storage and there's no HA.
  # Nothing on it needs keeping, and builds and containers run faster on
  # local disk than over NFS.
  proxmoxNode = "proxmox4";
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:07";
  cpuCores = 8;
  # Builds and tests get every CPU feature; it never migrates.
  cpuType = "host";
  memoryMb = 16384;
  diskSizeGb = 200;
  datastore = "local-lvm";
  tags = [ "homelab" "agents" "workbench" ];
}
