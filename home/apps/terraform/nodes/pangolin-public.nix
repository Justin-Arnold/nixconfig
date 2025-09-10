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
      token = var.hcloud_token
    }
  '';

  home.file."${proj}/versions.tf".text = ''
    terraform {
      required_version = ">= 1.6.0"
    }
  '';

  home.file."${proj}/variables.tf".text = ''
    variable "hcloud_token" {
      description = "Hetzner Cloud API Token"
      type        = string
      sensitive   = true
    }
    variable "name" { default = "pangolin-public" }
    variable "server_type" { default = "cx21" }  # 2 vCPU, 4GB RAM
    variable "location" { default = "ash" }      # or "nbg1", "hel1", etc.
    variable "image" { default = "ubuntu-22.04" }
    variable "ssh_pubkey_path" { default = "~/.ssh/id_ed25519.pub" }
    variable "ci_user" { default = "justin" }
  '';

}

