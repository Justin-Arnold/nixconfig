# Dedicated router <-> cloud WireGuard peer. The router dials out to this host
# (works with static, dynamic or CGNAT lab WAN). Only the listed lab subnets
# are routed; the host's default route stays on its public interface.
#
# Values are set in configuration.nix. The router side (OPNsense) is described
# in docs/lab118-services/REFERENCE.md.
{ config, lib, pkgs, ... }:
let
  cfg = config.lab118.wireguard;
in
{
  options.lab118.wireguard = {
    enable = lib.mkEnableOption "the router <-> lab118-services WireGuard peer";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
    };

    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.118.0.1/30";
      description = "This host's tunnel address with prefix. Must not overlap lab or Docker networks.";
    };

    routerPublicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };

    routerTunnelAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.118.0.2";
    };

    labSubnets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "10.0.0.0/24" ];
      description = "Lab networks reachable through the tunnel (confirmed, not guessed).";
    };

    labDns = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.0.0.1";
    };

    labDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "host.internal" ];
      description = "Domains resolved by lab DNS over the tunnel; everything else uses public DNS.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.address != null && cfg.routerPublicKey != null && cfg.routerTunnelAddress != null
          && cfg.labSubnets != [ ] && cfg.labDns != null;
        message = "lab118.wireguard: address, routerPublicKey, routerTunnelAddress, labSubnets and labDns must all be set.";
      }
      {
        assertion = cfg.address == null || !(lib.hasPrefix "172." cfg.address);
        message = "lab118.wireguard.address must not be in 172.16.0.0/12 (Docker networks).";
      }
    ];

    sops.secrets."wireguard/private-key" = {
      owner = "systemd-network";
      group = "systemd-network";
      mode = "0400";
      restartUnits = [ "systemd-networkd.service" ];
    };

    systemd.network.netdevs."40-wg-lab" = {
      netdevConfig = {
        Kind = "wireguard";
        Name = "wg-lab";
      };
      wireguardConfig = {
        PrivateKeyFile = config.sops.secrets."wireguard/private-key".path;
        ListenPort = cfg.listenPort;
      };
      wireguardPeers = [
        {
          PublicKey = cfg.routerPublicKey;
          AllowedIPs = [ "${cfg.routerTunnelAddress}/32" ] ++ cfg.labSubnets;
          PersistentKeepalive = 25;
        }
      ];
    };

    systemd.network.networks."40-wg-lab" = {
      matchConfig.Name = "wg-lab";
      address = [ cfg.address ];
      routes = map (subnet: { Destination = subnet; }) cfg.labSubnets;
      dns = [ cfg.labDns ];
      domains = map (d: "~${d}") cfg.labDomains;
      networkConfig.DNSDefaultRoute = false;
      linkConfig.RequiredForOnline = "no";
    };

    networking.firewall.allowedUDPPorts = [ cfg.listenPort ];

    # `wg show` for diagnostics; networkd manages the interface itself.
    environment.systemPackages = [ pkgs.wireguard-tools ];

    # Lab producers reach machine intake only: Alerta API (API key auth),
    # Node-RED /intake/ endpoints (nginx allowlist) and ntfy (ntfy auth).
    networking.firewall.interfaces.wg-lab.allowedTCPPorts = [ 1880 5000 8080 ];
  };
}
