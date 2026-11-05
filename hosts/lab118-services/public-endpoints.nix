# Endpoints that must work without Pangolin or browser login. DNS for these
# names points straight at this host (A records in the lab118.xyz zone).
#
#   ntfy.lab118.xyz    ntfy (its own auth: deny-all default, users/tokens)
#   intake.lab118.xyz  only Uptime Kuma push heartbeats (/api/push/<token>)
#
# Dashboards (Alerta UI, Node-RED editor, Kuma UI) are NOT served here; they
# go through Pangolin via the local Newt connector.
{ config, ... }:
let
  domain = config.lab118.directDomain;
in
{
  security.acme = {
    acceptTerms = true;
    defaults.email = "hello@justin-arnold.com";
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;

    appendHttpConfig = ''
      limit_req_zone $binary_remote_addr zone=intake:10m rate=60r/m;
    '';

    # Requests by IP or for unknown names get nothing (no cert, no content).
    virtualHosts."_" = {
      default = true;
      rejectSSL = true;
      locations."/".return = "444";
    };

    virtualHosts."ntfy.${domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          proxy_request_buffering off;
          proxy_read_timeout 3m;
          proxy_send_timeout 3m;
          client_max_body_size 20m;
        '';
      };
    };

    virtualHosts."intake.${domain}" = {
      enableACME = true;
      forceSSL = true;
      locations."/api/push/" = {
        proxyPass = "http://127.0.0.1:${toString config.roles.uptimeKuma.hostPort}";
        extraConfig = ''
          limit_req zone=intake burst=30 nodelay;
        '';
      };
      locations."/".return = "404";
    };

    # Machine intake for lab producers (over WireGuard) and local containers.
    # Only Node-RED HTTP-in endpoints under /intake/ are forwarded; the editor
    # and its admin API are never reachable on this port.
    virtualHosts.node-red-intake = {
      listen = [
        {
          addr = "0.0.0.0";
          port = 1880;
        }
      ];
      locations."/intake/".proxyPass = "http://127.0.0.1:${toString config.roles.notificationsStack.nodeRed.hostPort}";
      locations."/".return = "403";
    };

    # Uptime Kuma's status-page API for Homarr on the dashboard VM in the lab,
    # over WireGuard only (the firewall opens this port on wg-lab alone). Only
    # GET requests under /api/status-page/ from the lab LAN get through; the
    # Kuma UI and its socket API stay behind Pangolin.
    virtualHosts.kuma-status-tunnel = {
      listen = [
        {
          addr = "0.0.0.0";
          port = 3002;
        }
      ];
      locations."/api/status-page/" = {
        proxyPass = "http://127.0.0.1:${toString config.roles.uptimeKuma.hostPort}";
        extraConfig = ''
          allow 10.0.0.0/24;
          deny all;
          limit_except GET { deny all; }
        '';
      };
      locations."/".return = "403";
    };
  };

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
