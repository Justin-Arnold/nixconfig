{ pkgs, osConfig, ... }:
let
  proj = "infra/tf/nocodb-vm";
in {
  home.file."${proj}/.envrc".text = ''
    dotenv "/run/secrets/proxmox.env"
    dotenv "/run/secrets/nocodb.env"
    dotenv "/run/secrets/onepassword.env"
  '';

  home.file."${proj}/providers.tf".text = ''
    terraform {
      required_providers {
        proxmox = {
          source  = "bpg/proxmox"
          version = ">= 0.60.0"
        }
        onepassword = {
          source = "1Password/onepassword"
          version = ">= 1.1.4"
        }
      }
    }
    provider "proxmox" {}
    provider "onepassword" {}
  '';

  home.file."${proj}/versions.tf".text = ''
    terraform {
      required_version = ">= 1.6.0"
    }
  '';

  home.file."${proj}/variables.tf".text = ''
    variable "node"         { default = "proxmox4" }
    variable "name"         { default = "nocodb" }
    variable "template_id"  { default = 9401 }
    variable "cpu_cores"    { default = 2 }
    variable "memory_mb"    { default = 8192 }
    variable "datastore"    { default = "local-lvm" }
    variable "disk_size_gb" { default = 120 }
    variable "ip_cidr"      { default = "10.0.0.69/24" }
    variable "gateway"      { default = "10.0.0.1" }
    variable "dns_servers"  { default = ["10.0.0.1"] }
    variable "ci_user"      { default = "justin" }
    variable "vault_id"     { default = "wvkcfshnywabj57qvtticf7tla" }
  '';

  home.file."${proj}/main.tf".text = ''
    variable "ssh_pubkey_files" {
      description = "Paths on the TF controller to .pub files (e.g. Mac, Ansible, controller)"
      type        = list(string)
      default     = [
        "~/.ssh/id_ed25519.pub",           # controller
        "~/.ssh/macbook.pub",              # your Mac
        "~/.ssh/ansible_controller.pub"    # a dedicated Ansible key (optional)
      ]
    }

    locals {
      key_strings = [ for f in var.ssh_pubkey_files : file(pathexpand(f)) ]
    }

    resource "tls_private_key" "client_key" {
      algorithm = "ED25519"
    }

    resource "onepassword_item" "ssh_key" {
      vault = var.vault_id
      title = "client-key-for-${var.name}"
      category = "ssh_key"
      
      section {
        field {
          label = "private_key"
          type = "concealed" 
          value = tls_private_key.client_key.private_key_pem
        }
      }
    }

    resource "proxmox_virtual_environment_vm" "nocodb" {
      name      = var.name
      node_name = var.node
      on_boot   = true

      # Match your BIOS style to the template (use seabios if your template is BIOS)
      bios       = "seabios"
      boot_order = ["virtio0"]

      clone {
        vm_id = var.template_id 
        full = true
      }

      cpu    { cores = var.cpu_cores }
      memory { dedicated = var.memory_mb }

      disk {
        datastore_id = var.datastore
        interface    = "virtio0"
        size         = var.disk_size_gb
      }

      network_device {
        bridge = "vmbr0"
        model = "virtio"
      }

      agent { enabled = true }

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
          keys     = local.key_strings
        }
      }
    }
  '';

  # Useful outputs for your Ansible step (decoupled from TF)
  home.file."${proj}/outputs.tf".text = ''
    output "name" {
      value = proxmox_virtual_environment_vm.nocodb.name
    }

    output "ipv4" {
      # first address of first NIC reported by the guest agent
      value = try(proxmox_virtual_environment_vm.nocodb.ipv4_addresses[0][0], null)
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
