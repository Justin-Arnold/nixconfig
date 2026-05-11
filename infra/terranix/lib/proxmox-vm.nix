{ inputs, lib }:
{
  name,
  proxmoxNode,
  vmId ? null,
  bootstrapTemplateId,
  bootstrapTemplateNode ? null,
  macAddress,
  cpuCores ? 2,
  cpuType ? null,
  memoryMb ? 2048,
  diskSizeGb ? 20,
  datastore ? "local-lvm",
  bridge ? "vmbr0",
  vlanId ? null,
  tags ? [ "homelab" ],
  targetUser ? "root",
}:
let
  hasManagedDisk = diskSizeGb != null;
  networkDevice =
    {
      bridge = bridge;
      disconnected = false;
      enabled = true;
      firewall = false;
      mac_address = macAddress;
      model = "virtio";
      mtu = 0;
      queues = 0;
      rate_limit = 0;
      trunks = "";
      vlan_id = if vlanId != null then vlanId else 0;
    };
in
{
  terraform.required_version = ">= 1.6.0";

  terraform.required_providers = {
    proxmox = {
      source = "bpg/proxmox";
      version = ">= 0.60.0";
    };
  };

  provider.proxmox = { };

  variable.bootstrap_public_key = {
    type = "string";
    description = "Public SSH key injected into the cloud-init user.";
  };

  resource =
    {
      proxmox_virtual_environment_vm.${name} =
        ({
          name = name;
          node_name = proxmoxNode;
          on_boot = true;
          bios = "seabios";
          boot_order = [ "scsi0" ];

          clone = {
            vm_id = bootstrapTemplateId;
            full = true;
          } // lib.optionalAttrs (bootstrapTemplateNode != null) {
            node_name = bootstrapTemplateNode;
          };

          serial_device = [
            {
              device = "socket";
            }
          ];

          cpu = {
            cores = cpuCores;
          } // lib.optionalAttrs (cpuType != null) {
            type = cpuType;
          };
          memory.dedicated = memoryMb;

          tags = tags;

          network_device = [
            networkDevice
          ];

          agent.enabled = true;

          initialization = {
            ip_config.ipv4 = {
              address = "dhcp";
            };
            user_account = {
              username = targetUser;
              keys = [ "\${var.bootstrap_public_key}" ];
            };
          };
        }
        // lib.optionalAttrs hasManagedDisk {
          disk = [
            {
              datastore_id = datastore;
              interface = "scsi0";
              size = diskSizeGb;
            }
          ];
        }
        // (if vmId == null then { } else { vm_id = vmId; }));
    };

  output.name.value = "\${proxmox_virtual_environment_vm.${name}.name}";
  output.node_name.value = proxmoxNode;
  output.vm_id.value = "\${proxmox_virtual_environment_vm.${name}.vm_id}";
  output.mac_address.value = macAddress;
  output.target_user.value = targetUser;
}
