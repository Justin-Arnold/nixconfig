# Endpoints that must work without Pangolin or browser login. DNS for these
# names points straight at this host (A records in the lab118.xyz zone).
#
#   ntfy.lab118.xyz    ntfy (its own auth: deny-all default, users/tokens)
#   intake.lab118.xyz  Uptime Kuma push heartbeats (/api/push/<token>), and
#                      GitHub's webhook deliveries (POST /github), passed over
#                      the tunnel to n8n on the automation VM, which refuses
#                      anything GitHub didn't sign
#
# Dashboards (Alerta UI, Node-RED editor, Kuma UI) are NOT served here; they
# go through Pangolin via the local Newt connector.
{ config, lib, ... }:
let
  domain = config.lab118.directDomain;
  automation = "automation.servicestack.xyz";
  github = config.services.nginx.virtualHosts."intake.${domain}".locations."= /github";
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
      # The name resolves through the tunnel (lab118.wireguard.labDomains) when
      # a delivery arrives, not when nginx starts, so a lab outage fails only
      # this path. n8n's server block lets this host reach /webhook/github and
      # nothing else.
      locations."= /github".extraConfig = ''
        limit_except POST { deny all; }
        limit_req zone=intake burst=30 nodelay;
        client_max_body_size 5m;
        resolver 127.0.0.53 valid=60s ipv6=off;
        set $automation ${automation};
        proxy_pass https://$automation/webhook/github;
        # GitHub's own headers, its signature among them, pass through as sent.
        proxy_set_header Host ${automation};
        proxy_ssl_server_name on;
        proxy_ssl_name ${automation};
        proxy_ssl_verify on;
        # nginx checks one level above the certificate by default, and Let's
        # Encrypt's chain (YE1, then Root YE, cross-signed by ISRG Root X2) is
        # longer, so every delivery would fail with a 502.
        proxy_ssl_verify_depth 3;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_connect_timeout 10s;
        proxy_read_timeout 30s;
      '';
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

  assertions = [
    {
      assertion = lib.hasInfix "limit_except POST { deny all; }" github.extraConfig
        && lib.hasInfix "proxy_pass https://$automation/webhook/github;" github.extraConfig
        && lib.hasInfix "proxy_ssl_verify on;" github.extraConfig;
      message = "lab118-services: intake's /github takes POST only and passes it to n8n's /webhook/github alone, checking n8n's certificate.";
    }
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
