# home-assistant: Home Assistant OS, which manages itself. nixconfig only
# makes its VM: no NixOS, so `install` and `switch` refuse it
# (infra/terranix/default.nix). See Justin's vault,
# 02. Areas/Homelab/Hosts/home-assistant.md.
{ inputs }:
let
  mkProxmoxVm = import ../lib/proxmox-vm.nix {
    inherit inputs;
    lib = inputs.nixpkgs.lib;
  };
in
mkProxmoxVm {
  name = "home-assistant";
  # Where it's created. Importing a qcow2 from an import storage needs
  # Proxmox 8.4 or later, and proxmox4 is still on 8. HA may run it anywhere
  # afterwards.
  proxmoxNode = "proxmox8";
  # Leave vmId unset: Justin explicitly selected automatic allocation.
  # The KVM image of Home Assistant OS 18.4, decompressed onto nas-shared by
  # hand before the VM is created (the vault note, "Creating the VM"). HAOS
  # updates itself after that, so this stays as it is.
  diskImage = "nas-shared:import/haos_ova-18.4.qcow2";
  machine = "q35";
  macAddress = "02:01:18:00:00:0d";
  cpuCores = 4;
  cpuType = "x86-64-v2-AES";
  memoryMb = 8192;
  diskSizeGb = 64;
  datastore = "nas-shared";
  tags = [
    "homelab"
    "home-assistant"
  ];
  ha = {
    enable = true;
    state = "started";
    comment = "Home Assistant OS; network radios, no node-local passthrough";
  };
}
