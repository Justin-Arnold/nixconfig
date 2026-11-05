{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "inference";
  # The RTX 3090 is in this node, so the VM lives here and never moves.
  proxmoxNode = "proxmox2";
  bootstrapTemplateId = 9999;
  bootstrapTemplateNode = "proxmox8";
  macAddress = "02:01:18:00:00:09";
  # Model loading, tokenising and Whisper's CPU side; it never migrates, so
  # it gets every CPU feature the node has.
  cpuCores = 16;
  cpuType = "host";
  # One model is mapped from the page cache and the rest is headroom for
  # moving a few MoE experts to the CPU if a candidate needs it.
  memoryMb = 65536;
  # Model files (13-20 GB each, a few kept for the model test), Whisper's
  # models and the nix store.
  diskSizeGb = 300;
  datastore = "local-lvm";
  machine = "q35";
  hostPci = [
    {
      device = "hostpci0";
      # The node's PCI resource mapping for the card (Datacenter, Resource
      # Mappings).
      mapping = "gtx3090";
      pcie = true;
      rombar = true;
      xvga = false;
    }
  ];
  tags = [ "homelab" "agents" "inference" ];
}
