{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "openclaw";
  # Where it's created. HA may run it anywhere afterwards.
  proxmoxNode = "proxmox4";
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:08";
  # One gateway process; the models run elsewhere.
  cpuCores = 2;
  # A model every node can run, so live migration works between different
  # Intel generations.
  cpuType = "x86-64-v2-AES";
  memoryMb = 4096;
  diskSizeGb = 30;
  # Disk and cloud-init drive both on shared storage, so any node can take over.
  datastore = "nas-shared";
  cloudInitDatastore = "nas-shared";
  tags = [ "homelab" "agents" "openclaw" ];
  ha = {
    enable = true;
    state = "started";
    comment = "OpenClaw, the chat front door to the agents, managed by Terraform";
  };
}
