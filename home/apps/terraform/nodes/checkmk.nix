{ pkgs, osConfig, ... }:
let
  proj = "infra/tf/checkmk-vm";
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
    variable "node"     { type = string  default = "proxmox4" }
    variable "name"         { type = string  default = "checkmk" }
    variable "template_id"  { type = number  default = 9401 }      # your NixOS template
    variable "cpu_cores"    { type = number  default = 4 }
    variable "memory_mb"    { type = number  default = 8192 }
    variable "datastore"    { type = string  default = "local-lvm" }
    variable "disk_size_gb" { type = number  default = 120 }
    variable "ip_cidr"      { type = string  default = "10.0.0.68/24" }
    variable "gateway"      { type = string  default = "10.0.0.1" }
    variable "dns_servers"  { type = list(string) default = ["10.0.0.1"] }
    variable "ci_user"      { type = string  default = "justin" }
    variable "ssh_pubkey"   { type = string  default = "~/.ssh/id_ed25519.pub" }
  '';

  home.file."${proj}/main.tf".text = ''
    resource "proxmox_virtual_environment_vm" "checkmk" {
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
      bridge = "vmbr0";
      model = "virtio"
    }

    agent { enabled = true }

    initialization {
      dns { servers = var.dns_servers }
      ip_config { ipv4 { address = var.ip_cidr  gateway = var.gateway } }
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
      value = proxmox_virtual_environment_vm.checkmk.name
    }

    output "ipv4" {
      # first address of first NIC reported by the guest agent
      value = try(proxmox_virtual_environment_vm.checkmk.ipv4_addresses[0][0], null)
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
