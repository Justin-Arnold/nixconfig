{ config, pkgs, lib, home-manager, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common
  ];

  systemProfile = {
    hostname = "omada-controller";
    stateVersion = "25.05";
    isServer = true;
  };

  virtualisation.oci-containers.containers.omada-controller = {
  image = "mbentley/omada-controller:5";
  autoStart = true;
  
  environment = {
    PUID = "508";
    PGID = "508";
    MANAGE_HTTP_PORT = "8088";
    MANAGE_HTTPS_PORT = "8043";
    PORTAL_HTTP_PORT = "8088";
    PORTAL_HTTPS_PORT = "8843";
    PORT_APP_DISCOVERY = "27001";
    PORT_DISCOVERY = "29810";
    PORT_MANAGER_V1 = "29811";
    PORT_ADOPT_V1 = "29812";
    PORT_UPGRADE_V1 = "29813";
    PORT_MANAGER_V2 = "29814";
    PORT_TRANSFER_V2 = "29815";
    PORT_RTTY = "29816";
    PORT_DEVICE_MONITOR = "29817";
    SHOW_SERVER_LOGS = "true";
    SHOW_MONGODB_LOGS = "false";
    SSL_CERT_NAME = "tls.crt";
    SSL_KEY_NAME = "tls.key";
    TZ = "Etc/UTC";
  };
  
  volumes = [
    "omada-data:/opt/tplink/EAPController/data"
    "omada-logs:/opt/tplink/EAPController/logs"
  ];
  
  extraOptions = [
    # Host networking mode (equivalent to network_mode: host)
    "--network=host"
    
    # Ulimits (file descriptor limits)
    "--ulimit=nofile=4096:8192"
    
    # Stop grace period (60 seconds)
    "--stop-timeout=60"
  ];
};

# Set the container backend (podman is recommended)
virtualisation.oci-containers.backend = "podman";

# Optional: Create a dedicated user for the omada controller
# This matches the PUID/PGID settings
users.users.omada = {
  uid = 508;
  isSystemUser = true;
  group = "omada";
  description = "Omada Controller user";
};

users.groups.omada = {
  gid = 508;
};

# Optional: Open firewall ports for Omada Controller
# Uncomment if you want NixOS to manage the firewall
networking.firewall = {
  allowedTCPPorts = [
    8088   # MANAGE_HTTP_PORT / PORTAL_HTTP_PORT
    8043   # MANAGE_HTTPS_PORT
    8843   # PORTAL_HTTPS_PORT
    27001  # PORT_APP_DISCOVERY
    29810  # PORT_DISCOVERY
    29811  # PORT_MANAGER_V1
    29812  # PORT_ADOPT_V1
    29813  # PORT_UPGRADE_V1
    29814  # PORT_MANAGER_V2
    29815  # PORT_TRANSFER_V2
    29816  # PORT_RTTY
    29817  # PORT_DEVICE_MONITOR
  ];
  allowedUDPPorts = [
    27001  # PORT_APP_DISCOVERY
    29810  # PORT_DISCOVERY
  ];
};

# Optional: Create a systemd service override for additional configuration
systemd.services.podman-omada-controller = {
  serviceConfig = {
    # Restart policy equivalent to "unless-stopped"
    Restart = "always";
    RestartSec = "10s";
  };
  
  # Ensure the service starts after network is ready
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
};

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
    ];
  };
}