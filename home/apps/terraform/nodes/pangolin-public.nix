{ pkgs, ... }:
let
  proj = "infra/tf/pangolin-public";
in {
  home.file."${proj}/.envrc".text = ''
    dotenv "/run/secrets/hetzner-pangolin.env"
  '';

  home.file."${proj}/providers.tf".text = ''
    terraform {
      required_providers {
        hcloud = {
          source  = "hetznercloud/hcloud"
          version = "~> 1.45"
        }
      }
    }
    
    provider "hcloud" {
      # Using environment variable HETZNER_TOKEN from .envrc
    }
  '';

  home.file."${proj}/versions.tf".text = ''
    terraform {
      required_version = ">= 1.6.0"
    }
  '';

  home.file."${proj}/variables.tf".text = ''
    variable "name" { default = "pangolin-public" }
    variable "server_type" { default = "cpx21" }  # 3 vCPU, 4GB RAM
    variable "location" { default = "ash" }
    variable "image" { default = "ubuntu-24.04" }
    variable "ci_user" { default = "justin" }
  '';

  home.file."${proj}/main.tf".text = ''
    resource "hcloud_ssh_key" "ansible_controller" {
      name       = "ansible-controller-key" 
      public_key = file("/run/secrets/ssh/ansible_controller/public")
    }

    resource "hcloud_ssh_key" "macmini" {
      name       = "macmini-key"
      public_key = file("/run/secrets/ssh/macmini/public")
    }

    resource "hcloud_server" "pangolin" {
      name         = var.name
      server_type  = var.server_type
      image        = var.image
      location     = var.location
      ssh_keys     = [
        hcloud_ssh_key.ansible_controller.id,
        hcloud_ssh_key.macmini.id
      ]
      
      user_data = <<-EOF
        #cloud-config
        users:
          - name: justin
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/bash

        packages:
          - curl
          - wget
          - ufw
          - fail2ban

        runcmd:
          - ufw allow ssh
          - ufw allow 80/tcp
          - ufw allow 443/tcp
          - ufw --force enable
          - systemctl enable fail2ban
          - systemctl start fail2ban
      EOF

      labels = {
        purpose = "pangolin-tunnel"
        env     = "production"
      }
    }

    # Floating IP for static public IP
    resource "hcloud_floating_ip" "pangolin" {
      type      = "ipv4"
      home_location = var.location
    }

    resource "hcloud_floating_ip_assignment" "pangolin" {
      floating_ip_id = hcloud_floating_ip.pangolin.id
      server_id      = hcloud_server.pangolin.id
    }
  '';

  home.file."${proj}/cloud-init.yml".text = ''
    #cloud-config
    users:
      - name: $${username}
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash

    packages:
      - curl
      - wget
      - ufw
      - fail2ban

    runcmd:
      - ufw allow ssh
      - ufw allow 80/tcp
      - ufw allow 443/tcp
      - ufw --force enable
      - systemctl enable fail2ban
      - systemctl start fail2ban
  '';

  home.file."${proj}/outputs.tf".text = ''
    output "name" {
      value = hcloud_server.pangolin.name
    }
    output "ipv4" {
      value = hcloud_server.pangolin.ipv4_address
    }
    output "floating_ip" {
      value = hcloud_floating_ip.pangolin.ip_address
    }
    output "ssh_command" {
      value = "ssh $${var.ci_user}@$${hcloud_floating_ip.pangolin.ip_address}"
    }
  '';

  home.file."${proj}/.gitignore".text = ''
    .terraform/
    terraform.tfstate
    terraform.tfstate.*
    crash.log
    override.tf
    override.tf.json
    override.tfvars
    *.auto.tfvars
    *.auto.tfvars.json
    .terraform.lock.hcl
  '';
}