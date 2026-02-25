# Terranix module — generates config.tf.json for the monitoring-vm Proxmox resource.
#
# Values marked "# TODO: adjust" must be updated to match your Proxmox environment
# before running `nix run .#monitoring-vm-apply`.
#
# Networking strategy: DHCP only. After first boot, retrieve the MAC address from
# the Proxmox console (Hardware tab) or your DHCP server's lease table, then
# configure a static lease on your router so the IP stays stable.
{ ... }:

{
  terraform.required_version = ">= 1.6.0";

  terraform.required_providers.proxmox = {
    source  = "bpg/proxmox";
    version = ">= 0.60.0";
  };

  # Credentials are read from environment variables:
  #   PROXMOX_VE_ENDPOINT   — e.g. https://proxmox.host.internal:8006
  #   PROXMOX_VE_API_TOKEN  — e.g. root@pam!terraform=<uuid>
  #   PROXMOX_VE_INSECURE   — set to "true" if using a self-signed cert
  # Source these from the sops-managed proxmox.env (see terraform-controller host).
  provider.proxmox = { };

  resource.proxmox_virtual_environment_vm."monitoring-vm" = {
    name      = "monitoring-vm";
    node_name = "proxmox4";  # TODO: adjust to your Proxmox node name
    vm_id     = 300;         # TODO: adjust to an unused VM ID in your cluster
    on_boot   = true;

    # BIOS + GRUB (matches disk-config.nix which uses BIOS boot partition)
    bios       = "seabios";
    boot_order = [ "scsi0" ]; # TODO: adjust if interface below changes

    cpu    = [{ cores = 2; }];
    memory = [{ dedicated = 4096; }];

    # VirtIO SCSI exposes the disk as /dev/sda (matches disk-config.nix).
    # Switch to interface = "virtio0" if you prefer /dev/vda (update disk-config accordingly).
    disk = [{
      datastore_id = "local-lvm"; # TODO: adjust to your datastore
      interface    = "scsi0";
      size         = 64;
      file_format  = "raw";
    }];

    network_device = [{
      bridge = "vmbr0"; # TODO: adjust to your Proxmox bridge
      model  = "virtio";
    }];

    # DHCP — no static address is assigned here.
    # The router assigns a stable lease once the MAC is registered.
    initialization = [{
      ip_config = [{
        ipv4 = [{ address = "dhcp"; }];
      }];
      user_account = [{
        username = "root";
        # TODO: add your public SSH key so nix-anywhere can connect:
        # keys = [ "ssh-ed25519 AAAA..." ];
        keys = [ ];
      }];
    }];

    agent = [{ enabled = true; }];

    tags = [ "monitoring" ];
  };

  output."monitoring-vm-ipv4" = {
    description = "DHCP-assigned IP — check the Proxmox console or your router's lease table.";
    value = "\${try(proxmox_virtual_environment_vm.monitoring-vm.ipv4_addresses[0][0], null)}";
  };
}
