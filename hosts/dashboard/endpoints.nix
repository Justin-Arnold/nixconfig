# How the dashboard and the Beszel hub are reached. Each name works two ways,
# and both end at the same nginx server blocks with a Let's Encrypt
# certificate (Porkbun DNS-01, because nothing on the Internet can reach this
# VM):
#
#   In the LAN and over the VPN, AdGuard rewrites dashboard.servicestack.xyz
#   and beszel.servicestack.xyz to this VM. This path keeps working when the
#   WAN is down.
#
#   From anywhere else the same names resolve to Pangolin, which asks for SSO
#   and then comes in through the home site's Newt (the pangolin-newt VM) to
#   this VM over HTTPS, like any other LAN client.
#
# Homarr's MCP endpoint and its OAuth routes are blocked in every server block
# that reaches Homarr (nginx/homarr-guard.conf).
{ config, lib, pkgs, ... }:
let
  dashboard = "dashboard.servicestack.xyz";
  beszel = "beszel.servicestack.xyz";
  homarr = "http://127.0.0.1:${toString config.roles.homarr.hostPort}";
  hub = "http://127.0.0.1:${toString config.services.beszel.hub.port}";

  lan = "10.0.0.0/24";
  vpn = "10.10.10.0/24";
  # lab118-services over WireGuard: Uptime Kuma's checks and its Beszel agent.
  tunnel = "10.118.0.1";
  # Containers on this host (Homarr calling the hub).
  docker = "172.17.0.0/16";
  # The home site's Newt. Pangolin traffic arrives from here, so it's inside
  # `lan` and has to be shut out explicitly where remote access doesn't belong.
  pangolin = "10.0.0.72";

  allow = sources: lib.concatMapStrings (s: "allow ${s};\n") sources + "deny all;\n";
  notViaPangolin = "deny ${pangolin};\n";
  guard = "include ${./nginx/homarr-guard.conf};\n";

  hubVhost = config.services.nginx.virtualHosts.${beszel};
  lanOnlyHubPaths = [ "^~ /_/" "= /api/beszel/agent-connect" ];
in
{
  sops.secrets."porkbun/api-key" = { };
  sops.secrets."porkbun/secret-api-key" = { };

  security.acme = {
    acceptTerms = true;
    defaults.email = "hello@justin-arnold.com";
    certs.${dashboard} = {
      extraDomainNames = [ beszel ];
      dnsProvider = "porkbun";
      # Check propagation against public DNS, not the lab's split-horizon view.
      dnsResolver = "1.1.1.1:53";
      credentialFiles = {
        PORKBUN_API_KEY_FILE = config.sops.secrets."porkbun/api-key".path;
        PORKBUN_SECRET_API_KEY_FILE = config.sops.secrets."porkbun/secret-api-key".path;
      };
      environmentFile = pkgs.writeText "porkbun-acme.env" ''
        PORKBUN_PROPAGATION_TIMEOUT=900
        PORKBUN_POLLING_INTERVAL=30
        PORKBUN_TTL=600
      '';
      group = config.services.nginx.group;
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;

    # Requests by IP or for unknown names get nothing (no certificate, no content).
    virtualHosts."_" = {
      default = true;
      rejectSSL = true;
      locations."/".return = "444";
    };

    virtualHosts.${dashboard} = {
      useACMEHost = dashboard;
      acmeRoot = null;
      forceSSL = true;
      extraConfig = guard;
      locations."= /api/health/live" = {
        proxyPass = homarr;
        extraConfig = allow [ lan vpn tunnel ];
      };
      locations."/" = {
        proxyPass = homarr;
        proxyWebsockets = true;
        extraConfig = allow [ lan vpn ] + ''
          client_max_body_size 50m;
        '';
      };
    };

    virtualHosts.${beszel} = {
      useACMEHost = dashboard;
      acmeRoot = null;
      forceSSL = true;
      # Agents in the lab and lab118-services's agent over the tunnel.
      locations."= /api/beszel/agent-connect" = {
        proxyPass = hub;
        proxyWebsockets = true;
        extraConfig = notViaPangolin + allow [ lan tunnel ] + ''
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
        '';
      };
      locations."= /api/health" = {
        proxyPass = hub;
        extraConfig = allow [ lan vpn tunnel ];
      };
      # PocketBase's superuser UI: settings, backups, OAuth. Never via Pangolin.
      locations."^~ /_/" = {
        proxyPass = hub;
        extraConfig = notViaPangolin + allow [ lan vpn ];
      };
      # Live updates are server-sent events.
      locations."/api/realtime" = {
        proxyPass = hub;
        extraConfig = allow [ lan vpn docker ] + ''
          proxy_buffering off;
          proxy_read_timeout 1h;
        '';
      };
      locations."/" = {
        proxyPass = hub;
        proxyWebsockets = true;
        extraConfig = allow [ lan vpn docker ];
      };
    };
  };

  assertions = [
    {
      # nginx takes the first matching allow/deny, so the deny has to lead.
      assertion = lib.all (path: lib.hasPrefix notViaPangolin hubVhost.locations.${path}.extraConfig) lanOnlyHubPaths;
      message = "dashboard: Beszel's superuser UI and agent endpoint must start by denying Pangolin's Newt (${pangolin}).";
    }
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
