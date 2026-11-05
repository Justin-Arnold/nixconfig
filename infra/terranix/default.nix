# Infrastructure-managed hosts. `platform` selects the provisioning flow in
# scripts/provisioning/provision-host.sh; `deployTarget` is where a cloud
# `switch` connects (cloud switches never run Terraform).
{ inputs }:
let
  proxmox = file: {
    platform = "proxmox";
    module = import file { inherit inputs; };
  };
  lab118Facts = import ../../hosts/lab118-services/facts.nix;
in
{
  dockhand = proxmox ./hosts/dockhand.nix;
  notifications = proxmox ./hosts/notifications.nix;
  pr-previews = proxmox ./hosts/pr-previews.nix;
  uptime-kuma = proxmox ./hosts/uptime-kuma.nix;

  lab118-services = {
    platform = "contabo";
    module = import ./hosts/lab118-services.nix { inherit inputs; };
    deployTarget = lab118Facts.ipv4.address;
  };
}
