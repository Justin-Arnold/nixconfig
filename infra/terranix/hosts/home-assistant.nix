{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "home-assistant";
  proxmoxNode = "proxmox4";
  # Leave vmId unset: Justin explicitly selected automatic allocation.
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:0b";
  cpuCores = 4;
  cpuType = "x86-64-v2-AES";
  memoryMb = 8192;
  diskSizeGb = 64;
  datastore = "nas-shared";
  cloudInitDatastore = "nas-shared";
  tags = [
    "homelab"
    "home-assistant"
  ];
  ha = {
    enable = true;
    state = "started";
    comment = "Fresh Home Assistant; network radios, no node-local passthrough";
  };
}
