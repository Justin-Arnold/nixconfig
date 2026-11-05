{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "agents";
  # Where it's created. HA may run it anywhere afterwards.
  proxmoxNode = "proxmox5";
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:06";
  # Paperclip and PostgreSQL now; the Hermes instances join later, one
  # process each.
  cpuCores = 4;
  # A model every node can run, so live migration works between different
  # Intel generations. "host" would pin it to identical CPUs.
  cpuType = "x86-64-v2-AES";
  memoryMb = 12288;
  diskSizeGb = 80;
  # Disk and cloud-init drive both on shared storage, so any node can take over.
  datastore = "nas-shared";
  cloudInitDatastore = "nas-shared";
  tags = [ "homelab" "agents" "paperclip" ];
  ha = {
    enable = true;
    state = "started";
    comment = "Paperclip and the Hermes agents, managed by Terraform";
  };
}
