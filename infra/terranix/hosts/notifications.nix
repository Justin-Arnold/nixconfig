{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "notifications";
  proxmoxNode = "proxmox5";
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:04";
  cpuCores = 2;
  cpuType = "host";
  memoryMb = 4096;
  diskSizeGb = 40;
  datastore = "nas-shared";
  tags = [ "homelab" "notifications" "monitoring" ];

  ha = {
    enable = true;
    state = "started";
    comment = "Notifications gateway managed by Terraform";
  };
}
