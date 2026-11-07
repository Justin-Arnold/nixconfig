{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "automation";
  # Where it's created. HA may run it anywhere afterwards.
  proxmoxNode = "proxmox4";
  # A fixed id. Proxmox hands out the lowest free one, so a failed attempt's id
  # comes straight back, and proxmox4 (still on Proxmox 8) then misses the
  # cloud-init drive proxmox8 has just cloned into that id's directory on
  # nas-shared. 144 had never been used when this host was made.
  vmId = 144;
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:0a";
  # n8n is unfree, so no binary cache has it and every switch that moves it
  # builds it here from source. Running it needs a fraction of this.
  cpuCores = 4;
  # A model every node can run, so live migration works between different
  # Intel generations.
  cpuType = "x86-64-v2-AES";
  memoryMb = 8192;
  diskSizeGb = 40;
  # Disk and cloud-init drive both on shared storage, so any node can take over.
  datastore = "nas-shared";
  cloudInitDatastore = "nas-shared";
  tags = [ "homelab" "automation" "n8n" ];
  ha = {
    enable = true;
    state = "started";
    comment = "n8n, the router between GitHub, Paperclip and Alerta, managed by Terraform";
  };
}
