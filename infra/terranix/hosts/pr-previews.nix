{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "pr-previews";
  proxmoxNode = "proxmox4";
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:02";
  cpuCores = 8;
  memoryMb = 32768;
  diskSizeGb = 256;
  datastore = "local-lvm";
  tags = [ "homelab" "preview" ];
}
