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
  # Where the cloud-init drive lives. The provider defaults it to local-lvm,
  # which ties the VM to its first node: HA can't recover it elsewhere and
  # migration has to copy it. HA VMs should put it on the same shared storage
  # as the disk.
  cloudInitDatastore ? null,
  bridge ? "vmbr0",
  vlanId ? null,
  tags ? [ "homelab" ],
  targetUser ? "root",
  ignoreBootstrapKeyChanges ? true,
  ha ? { enable = false; },
  lifecycleIgnoreChanges ? [ ],
}:
let
  hasManagedDisk = diskSizeGb != null;
  haEnabled = (ha.enable or false);
  effectiveLifecycleIgnoreChanges =
    lifecycleIgnoreChanges
    ++ lib.optional ignoreBootstrapKeyChanges "initialization[0].user_account[0].keys";
  effectiveVmLifecycleIgnoreChanges =
    effectiveLifecycleIgnoreChanges
    ++ lib.optional haEnabled "node_name";
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

  terraform.backend.s3 = { };

  terraform.required_providers = {
    proxmox = {
      source = "bpg/proxmox";
      # proxmox_haresource (below) is the short resource name added in 0.100.0.
      version = ">= 0.100.0";
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
          } // lib.optionalAttrs (cloudInitDatastore != null) {
            datastore_id = cloudInitDatastore;
          };
        }
        // lib.optionalAttrs (effectiveVmLifecycleIgnoreChanges != [ ]) {
          lifecycle.ignore_changes = effectiveVmLifecycleIgnoreChanges;
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
    }
    // lib.optionalAttrs haEnabled {
      proxmox_haresource.${name} =
        {
          resource_id = "vm:\${proxmox_virtual_environment_vm.${name}.vm_id}";
          state = ha.state or "started";
          comment = ha.comment or "Managed by Terraform";
        }
        // lib.optionalAttrs (ha ? group && ha.group != null) {
          group = ha.group;
        };
    };

  output.name.value = "\${proxmox_virtual_environment_vm.${name}.name}";
  output.node_name.value = proxmoxNode;
  output.vm_id.value = "\${proxmox_virtual_environment_vm.${name}.vm_id}";
  output.mac_address.value = macAddress;
  output.target_user.value = targetUser;
  output.ha_enabled.value = haEnabled;
}
