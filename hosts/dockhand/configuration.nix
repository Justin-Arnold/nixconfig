{ config, lib, inputs, sops-nix, ... }:
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

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "dockhand";
    stateVersion = "25.05";
    isServer = true;
  };

  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  roles.docker = {
    enable = true;
    dockhandManaged.enable = false;
  };

  networking.useDHCP = lib.mkDefault true;

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/secrets.yaml;
  sops.secrets."dockhand/env" = {
    owner = "root";
    group = "root";
    mode = "0400";
  };

  systemd.tmpfiles.rules = [
    "d /opt/dockhand 0750 root root -"
  ];

  virtualisation.oci-containers.containers.dockhand = {
    image = "fnsys/dockhand:latest";
    autoStart = true;
    ports = [ "3000:3000" ];
    volumes = [
      "/var/run/docker.sock:/var/run/docker.sock"
      "/opt/dockhand:/opt/dockhand"
    ];
    environment = {
      DATA_DIR = "/opt/dockhand";
      HOST_DATA_DIR = "/opt/dockhand";
      NODE_ENV = "production";
    };
    environmentFiles = [
      config.sops.secrets."dockhand/env".path
    ];
  };

  networking.firewall.allowedTCPPorts = [ 3000 ];
}
