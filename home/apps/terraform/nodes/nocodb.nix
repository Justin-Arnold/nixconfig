{ pkgs, osConfig, ... }:
let
  proj = "infra/tf/nocodb-vm";

  defaults = {
    name        = "nocodb";
    adguard_url = "http://10.0.0.1:3000";
    ip_cidr     = "10.0.0.69/24";
    vault_id    = "wvkcfshnywabj57qvtticf7tla";
  };
in {
  home.file."${proj}/.envrc".text = ''
    dotenv "/run/secrets/proxmox.env"
    dotenv "/run/secrets/onepassword.env"
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
    
    variable "adguard_url"      { default = "http://10.0.0.1:3000" }
  '';

  home.file."${proj}/main.tf".text = ''

    resource "null_resource" "onepassword_ssh_key" {
      provisioner "local-exec" {
        command = <<-EOF
          # Create SSH key in 1Password
          op item create --category ssh \
            --title "ssh-host-${defaults.name}" \
            --vault ${defaults.vault_id} > /tmp/op_ssh_output.txt
          
          # Extract the SSH key ID for later use
          SSH_KEY_ID=$(cat /tmp/op_ssh_output.txt | grep "ID:" | awk '{print $$2}')
          echo "SSH_KEY_ID=$${SSH_KEY_ID}" > /tmp/op_ssh_id.env
          
          # Clean up temp file
          rm -f /tmp/op_ssh_output.txt
        EOF
      }

      # Recreate if VM name changes
      triggers = {
        vm_name = var.name
      }
    }

    data "external" "ssh_public_key" {
      depends_on = [null_resource.onepassword_ssh_key]
      program = ["bash", "-c", "PUBLIC_KEY=$(op read \"op://${defaults.vault_id}/ssh-host-${defaults.name}/public key\") && echo \"{\\\"public_key\\\": \\\"$${PUBLIC_KEY}\\\"}\""]
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
          keys = [data.external.ssh_public_key.result.public_key]
        }
      }
    }

    # Add DNS record to AdGuard after VM is created
    resource "null_resource" "add_dns_record" {
      depends_on = [proxmox_virtual_environment_vm.nocodb]
      
      provisioner "local-exec" {
        command = <<-EOF
          curl -X POST "${defaults.adguard_url}/control/rewrite/add" \
            -H "Content-Type: application/json" \
            -d '{
              "domain": "${defaults.name}.host.internal",
              "answer": "10.0.0.69"
            }'
        EOF
      }

      # Recreate if IP address changes
      triggers = {
        ip_address = split("/", var.ip_cidr)[0]
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

    output "hostname" {
      value = "${defaults.name}.host.internal"
    }

    output "ssh_public_key" {
      value = data.external.ssh_public_key.result.public_key
      description = "Public SSH key from 1Password"
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