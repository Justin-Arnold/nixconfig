{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "uptime-kuma";
  proxmoxNode = "proxmox5";
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:01";
  cpuCores = 2;
  memoryMb = 4096;
  diskSizeGb = 40;
  datastore = "local-lvm";
  tags = [ "homelab" "monitoring" ];
}
