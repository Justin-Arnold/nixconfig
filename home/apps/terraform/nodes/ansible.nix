{ pkgs, ... }:
let
  proj = "infra/tf/ansible-vm";
in {
  # Create the project directory and files (symlinked from the Nix store)
  home.file."${proj}/.envrc".text = ''
    dotenv "/run/secrets/proxmox.env"
  '';

  home.file."${proj}/providers.tf".text = ''
    terraform {
      required_providers {
        proxmox = {
          source  = "bpg/proxmox"
          version = ">= 0.55.0"
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

  home.file."${proj}/main.tf".text = ''
    variable "node"         { default = "proxmox4" }
    variable "name"         { default = "ansible-controller" }
    variable "template_id"  { default = 9000}
    variable "cpu_cores"    { default = 2 }
    variable "memory_mb"    { default = 4096 }
    variable "datastore"    { default = "local-lvm" }
    variable "disk_size_gb" { default = 40 }
    variable "ip_cidr"      { default = "10.0.0.41/24" }
    variable "gateway"      { default = "10.0.0.1" } 
    variable "dns_servers"  { default = ["10.0.0.1"] }
    variable "ci_user"      { default = "justin" }
    variable "ssh_pubkey"   { default = "~/.ssh/id_ed25519.pub" }

    resource "proxmox_virtual_environment_vm" "ansible" {
      name      = var.name
      node_name = var.node
      on_boot   = true

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

      agent {
        enabled = true
      }

      initialization {
        dns {
          servers = var.dns_servers
        }

        ip_config {
          ipv4 {
            address = var.ip_cidr
            gateway = var.gateway
          }
        }

        user_account {
          username = var.ci_user
          # read the SSH public key from your workstation user; if the file isn't present this will error
          keys = [file(pathexpand(var.ssh_pubkey))]
        }
      } 
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