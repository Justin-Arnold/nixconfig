{ pkgs, ... }:
let
  proj = "infra/tf/ansible-vm";
in {
  home.stateVersion = "25.05";


  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;

  # Create the project directory and files (symlinked from the Nix store)
  home.file."${proj}/.envrc".text = ''
    dotenv "/run/secrets/proxmox.env"
  '';

  home.file."${proj}/providers.tf".text = ''
    terraform {
      required_providers {
        proxmox = { source = "bpg/proxmox" }
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
    variable "node"       { default = "proxmox4" }
    variable "template"   { default = "9000" }
    variable "name"       { default = "ansible-controller" }
    variable "vm_ip"      { default = "10.0.0.41/24" }
    variable "gw"         { default = "10.0.0.1" }
    variable "sshkey"     { default = "~/.ssh/id_ed25519.pub" }
    variable "storage"    { default = "local-lvm" }
    variable "disk_size"  { default = "40G" }
    variable "bootdisk"   { default = "virtio0" }
    variable "disk_bus"   { default = "virtio" }

    resource "proxmox_vm_qemu" "ansible" {
      name        = var.name
      target_node = var.node
      clone       = var.template
      full        = true

      cores  = 2
      memory = 4096

      bootdisk = var.bootdisk
      disk {
        type    = var.disk_bus
        storage = var.storage
        size    = var.disk_size
      }

      network { model = "virtio"; bridge = "vmbr0" }

      os_type   = "cloud-init"
      ciuser    = "justin"
      sshkeys   = file(var.sshkey)
      ipconfig0 = format("ip=%s,gw=%s", var.vm_ip, var.gw)
      nameserver = "10.0.0.1"
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