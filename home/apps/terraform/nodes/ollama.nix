{ pkgs, ... }:
let
  proj = "infra/tf/ollama-vm";
in {
  home.file."${proj}/.envrc".text = ''
    dotenv "/run/secrets/proxmox.env"
  '';

  home.file."${proj}/providers.tf".text = ''
    terraform {
      required_providers {
        proxmox = {
          source  = "bpg/proxmox"
          version = ">= 0.60.0"
        }
      }
    }
    provider "proxmox" {}
  '';

  home.file."${proj}/versions.tf".text = ''
    terraform {
      required_version = ">= 1.6.0"
    }
  '';

  home.file."${proj}/variables.tf".text = ''
    variable "node"         { default = "proxmox2" }
    variable "name"         { default = "ollama-gpu" }
    variable "template_id"  { default = 9201 }
    variable "cpu_cores"    { default = 16 }
    variable "memory_mb"    { default = 122880 } # 124 GiB
    variable "datastore"    { default = "local-lvm" }
    variable "disk_size_gb" { default = 700 }
    variable "ip_cidr"      { default = "10.0.0.63/24" }
    variable "gateway"      { default = "10.0.0.1" } 
    variable "dns_servers"  { default = ["10.0.0.1"] }
    variable "ci_user"      { default = "justin" }
    variable "ssh_pubkey"   { default = "~/.ssh/id_ed25519.pub" }

    # GPU passthrough: prefer a Proxmox Resource Mapping name (e.g., "GPU0"),
    # otherwise set an explicit PCI ID like "0000:65:00.0".
    variable "gpu_mapping"  { default = "gtx3090" }
    variable "gpu_pci_id"   { default = "0000:01:00.0" }
  '';

  home.file."${proj}/main.tf".text = ''
    resource "proxmox_virtual_environment_vm" "ollama" {
      name      = var.name
      node_name = var.node
      on_boot   = true

      # Good defaults for GPU passthrough
      bios    = "seabios"
      machine = "q35"

      boot_order = ["virtio0", "ide2", "net0"]

      clone {
        vm_id = var.template_id
        full  = true
      }

      cpu {
        cores = var.cpu_cores
      }

      memory {
        dedicated = var.memory_mb
      }

      disk {
        datastore_id = var.datastore
        interface    = "virtio0"
        size         = var.disk_size_gb
      }

      network_device {
        bridge = "vmbr0"
        model  = "virtio"
      }

      agent { enabled = true }

      # Choose ONE: mapping or id (if set); otherwise no hostpci is added.
      dynamic "hostpci" {
        for_each = var.gpu_mapping != "" ? [1] : []
        content {
          device  = "hostpci0"
          mapping = var.gpu_mapping  # uses Proxmox Resource Mapping
          pcie    = true
          rombar  = true
          xvga    = false
        }
      }

      dynamic "hostpci" {
        for_each = var.gpu_mapping == "" && var.gpu_pci_id != "" ? [1] : []
        content {
          device = "hostpci0"
          id     = var.gpu_pci_id    # raw PCI BDF
          pcie   = true
          rombar = true
          xvga   = false
        }
      }

      initialization {
        dns { servers = var.dns_servers }

        ip_config {
          ipv4 {
            address = var.ip_cidr
            gateway = var.gateway
          }
        }

        user_account {
          username = var.ci_user
          keys     = [file(pathexpand(var.ssh_pubkey))]
        }
      }
    }
  '';

  # Useful outputs for your Ansible step (decoupled from TF)
  home.file."${proj}/outputs.tf".text = ''
    output "name" {
      value = proxmox_virtual_environment_vm.ollama.name
    }

    output "ipv4" {
      # first address of first NIC reported by the guest agent
      value = try(proxmox_virtual_environment_vm.ollama.ipv4_addresses[0][0], null)
    }
  '';

  home.file."${proj}/.gitignore".text = ''
    .terraform/
    terraform.tfstate
    terraform.tfstate.*
    crash.log
    override.tf
    override.tfvars
    *.auto.tfvars
  '';
}
