{ config, lib, inputs, ... }:
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/docker.nix
    ];

  systemProfile = {
    hostname = "uptime-kuma";
    stateVersion = "25.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda. Keep the boot target explicit so install-time GRUB assertions
  # stay stable.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  roles.docker.enable = true;

  networking.useDHCP = lib.mkDefault true;

  virtualisation.oci-containers.containers.uptime-kuma = {
    image = "louislam/uptime-kuma:2";
    pull = "always";
    autoStart = true;
    ports = [ "3001:3001" ];
    volumes = [ "uptime-kuma:/app/data" ];
  };

  networking.firewall.allowedTCPPorts = [ 3001 ];
}
