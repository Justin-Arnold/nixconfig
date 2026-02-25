{ config, pkgs, lib, sops-nix, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disk-config.nix
    ../../modules/common
    ../../modules/profiles/server.nix
    ../../modules/platforms/nixos
    ../../modules/roles/docker.nix

    sops-nix.nixosModules.sops
  ];

  systemProfile = {
    hostname    = "monitoring-vm";
    stateVersion = "25.05";
    isServer    = true;
  };

  ############################################################
  ## Boot — override server.nix default (/dev/vda) because
  ## this VM exposes its disk as /dev/sda (VirtIO SCSI).
  ############################################################
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  ############################################################
  ## Networking — DHCP only.
  ## A static lease will be assigned on the router/DHCP server
  ## once the VM's MAC address is known after first boot.
  ## Do NOT set a static IP here.
  ############################################################

  ############################################################
  ## Secrets (sops-nix)
  ############################################################
  sops.age.keyFile     = "/root/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/secrets.yaml;

  sops.secrets."healthchecks/secret-key" = { };

  # Render a Docker-compatible env file at runtime so the secret
  # never lands in the Nix store.
  sops.templates."healthchecks.env" = {
    path    = "/run/secrets-env/healthchecks.env";
    content = ''
      SECRET_KEY=${config.sops.placeholder."healthchecks/secret-key"}
    '';
    mode  = "0400";
    owner = "root";
  };

  ############################################################
  ## Docker (OCI container backend)
  ############################################################
  roles.docker.enable = true;

  ############################################################
  ## Services
  ############################################################

  # --- Uptime Kuma (port 3001) ----------------------------
  services.uptime-kuma.enable = true;

  # --- Netdata (port 19999) --------------------------------
  services.netdata.enable = true;

  # --- Healthchecks (port 8000) ----------------------------
  # No upstream NixOS module exists; run as an OCI container.
  virtualisation.oci-containers.containers.healthchecks = {
    image     = "healthchecks/healthchecks:latest";
    autoStart = true;
    ports     = [ "8000:8000" ];

    # SECRET_KEY is injected at runtime from the sops-managed env file.
    environmentFiles = [ "/run/secrets-env/healthchecks.env" ];

    environment = {
      ALLOWED_HOSTS = "*";
      DB            = "sqlite3";
      DEBUG         = "False";
    };

    volumes = [ "healthchecks-data:/data" ];
  };

  ############################################################
  ## Firewall
  ############################################################
  networking.firewall.allowedTCPPorts = [
    22    # SSH (also enforced by server.nix; listed here for visibility)
    3001  # Uptime Kuma
    8000  # Healthchecks
    19999 # Netdata
  ];
}
