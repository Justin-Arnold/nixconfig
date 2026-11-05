# lab118-services: general-purpose cloud host (Contabo Cloud VPS 12, EU).
# Initial workloads: notification stack, Uptime Kuma, external and
# WireGuard-based monitoring of the lab. See docs/lab118-services/REFERENCE.md.
{ config, lib, inputs, sops-nix, ... }:
let
  facts = config.lab118.facts;
  secrets = config.roles.dopplerSecrets.paths;
  dopplerLayout = import ./doppler-secrets.nix;
  wg = config.lab118.wireguard;

  # Operator key: can decrypt the host SOPS file and the Doppler cache for
  # recovery. Its private half never leaves the operator machine.
  operatorAgeRecipient = "age1ljfvx33psxcat4wwjpq6u26f5fv9jzntg8z266mhykpxh78upalqxfflz3";

  macMiniKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com";

  containerPorts = lib.concatMap (c: c.ports) (lib.attrValues config.virtualisation.oci-containers.containers);
  publicTcpPorts = lib.sort lib.lessThan (lib.unique config.networking.firewall.allowedTCPPorts);
  publicUdpPorts = lib.unique config.networking.firewall.allowedUDPPorts;
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./networking.nix
      ./wireguard.nix
      ./public-endpoints.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/docker.nix
      ../../modules/roles/doppler-secrets.nix
      ../../modules/roles/notifications-stack.nix
      ../../modules/roles/uptime-kuma.nix

      sops-nix.nixosModules.sops
    ];

  options.lab118.facts = lib.mkOption {
    type = lib.types.attrs;
    default = import ./facts.nix;
    description = "Provider and inspection facts (addresses, MAC, disk). See facts.nix.";
  };

  options.lab118.directDomain = lib.mkOption {
    type = lib.types.str;
    default = "lab118.xyz";
    description = ''
      Domain for names that resolve straight to this host (ntfy., intake.).
      Dashboards stay on Pangolin's domain (servicestack.xyz).
    '';
  };

  config = {
    systemProfile = {
      hostname = "lab118-services";
      stateVersion = "26.05";
      isServer = true;
    };

    profiles.server = {
      platform = "cloud";
      # Only the operator's Mac Mini key; lab controllers are not trusted here.
      authorizedKeys = [ macMiniKey ];
      # Upgrades are deliberate: nix flake update + nix run .#switch.
      autoUpgrade.enable = false;
    };

    # Internet-facing service host: no Home Manager user environment at all
    # (not even the server terminal setup with its dev toolchains). Keeps the
    # closure small and deploys independent of user-tool downloads.
    home-manager.users = lib.mkForce { };

    ############################################################
    ## Users and bootstrap secrets (SOPS, host-scoped key)
    ############################################################
    # Passwords come only from configuration: justin is key-only, root has a
    # break-glass password for the Contabo VNC console (SSH root login is off).
    users.mutableUsers = false;
    users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

    sops = {
      defaultSopsFile = ../../secrets/hosts/lab118-services.yaml;
      # Dedicated host identity, installed by `nix run .#install`. The
      # operator's broad key is never copied to this host.
      age.keyFile = "/var/lib/sops-nix/key.txt";
      age.sshKeyPaths = [ ];
      gnupg.sshKeyPaths = [ ];

      secrets."doppler/service-token" = {
        mode = "0400";
        restartUnits = [ "doppler-secrets-refresh.service" ];
      };
      secrets."root/console-password-hash".neededForUsers = true;
    };

    ############################################################
    ## Application secrets (Doppler lab118-services/prd)
    ############################################################
    roles.dopplerSecrets = {
      enable = true;
      tokenFile = config.sops.secrets."doppler/service-token".path;
      extraRecipients = [ operatorAgeRecipient ];
      inherit (dopplerLayout) outputs validators;
    };

    ############################################################
    ## Workloads
    ############################################################
    roles.docker = {
      enable = true;
      dockhandManaged.enable = false;
    };

    roles.notificationsStack = {
      enable = true;
      ntfy = {
        baseUrl = "https://ntfy.${config.lab118.directDomain}";
        behindProxy = true;
      };
      alerta.extraCorsOrigins = [ "https://alerta.servicestack.xyz" ];
      # 1880 on the host is the nginx intake allowlist; Node-RED itself is loopback-only.
      nodeRed.hostPort = 1881;
      images = {
        apprise = "caronc/apprise:1.5.4@sha256:c5ea17408c10fd84c8fdb05a421114a1a677b16343c274bf9b1a55701b530829";
        nodeRed = "nodered/node-red:4.1.12@sha256:c81912d66cb3639170484395ada550c94dfe0a56289cfaec3c8e6dec31f0d164";
      };
      secrets = {
        alertaSecretKey = secrets.alertaSecretKey;
        alertaAdminUser = secrets.alertaAdminUser;
        alertaAdminPassword = secrets.alertaAdminPassword;
        alertaApiKey = secrets.alertaApiKey;
        appriseConfig = secrets.appriseConfig;
        ntfyEnvironmentFile = secrets.ntfyEnv;
        nodeRedEnvironmentFile = secrets.nodeRedEnv;
        units = [ "doppler-secrets.service" ];
      };
    };

    roles.uptimeKuma = {
      enable = true;
      image = "louislam/uptime-kuma:2.5.5@sha256:c74379ac4509ce2d2c2633f509e67003ee2e45b6e995c5e43fc101f45a0e1fbe";
      # Notification integrations can target the local stack by its usual name.
      extraHosts = [ "notifications.host.internal:host-gateway" ];
    };

    # Router <-> cloud tunnel (OPNsense instance "lab118-cloud" dials out to
    # us). Tunnel 10.118.0.0/30 does not overlap the LAN (10.0.0.0/24), the
    # road-warrior VPN (10.10.10.0/24) or Docker (172.16.0.0/12). Only the LAN
    # is routed; only *.host.internal is resolved through the tunnel.
    lab118.wireguard = {
      enable = true;
      # Public key of the OPNsense "lab118-cloud" instance.
      routerPublicKey = "G5J3IbliB1PfRavKWU+Cl6q+SbEDS9gK7hGI9ZdeBwo=";
      address = "10.118.0.1/30";
      routerTunnelAddress = "10.118.0.2";
      labSubnets = [ "10.0.0.0/24" ];
      # AdGuard Home on the router, asked at the router's tunnel address: asked at
      # 10.0.0.1 it answers UDP from 10.118.0.2, and those replies are dropped.
      labDns = "10.118.0.2";
    };

    # Cloud-side Pangolin connector; dashboards no longer depend on the lab's Newt.
    services.newt = {
      enable = true;
      environmentFile = secrets.newtEnv;
      settings.endpoint = "https://tunnel.servicestack.xyz";
    };

    # Containers reach host services via host-gateway (docker0), never "localhost".
    networking.firewall.interfaces.docker0.allowedTCPPorts = [ 1880 5000 8080 ];

    ############################################################
    ## Guards
    ############################################################
    assertions = [
      {
        assertion = facts.macAddress != null && facts.ipv4.prefixLength != null
          && facts.ipv4.gateway != null && facts.diskDevice != null;
        message = ''
          lab118-services: facts.nix is incomplete (macAddress, ipv4.prefixLength,
          ipv4.gateway, diskDevice). Fill it from scripts/provisioning/inspect-cloud-host.sh
          before installing or switching.
        '';
      }
      {
        assertion = facts.ipv6.address == null || (facts.ipv6.prefixLength != null && facts.ipv6.gateway != null);
        message = "lab118-services: ipv6.address is set but prefixLength/gateway are missing.";
      }
      {
        assertion = publicTcpPorts == [ 22 80 443 ];
        message = "lab118-services: public TCP ports must be exactly 22, 80, 443 (got ${toString publicTcpPorts}).";
      }
      {
        assertion = publicUdpPorts == lib.optional wg.enable wg.listenPort;
        message = "lab118-services: unexpected public UDP ports: ${toString publicUdpPorts}.";
      }
      {
        # Docker-published ports bypass the NixOS firewall.
        assertion = lib.all (p: lib.hasPrefix "127.0.0.1:" p) containerPorts;
        message = "lab118-services: every container port must be published on 127.0.0.1 (got ${toString containerPorts}).";
      }
    ];
  };
}
