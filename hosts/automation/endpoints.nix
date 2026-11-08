# How n8n is reached. Its name works two ways, and both end at the same nginx
# server block with a Let's Encrypt certificate (Porkbun DNS-01, because
# nothing on the Internet can reach this VM):
#
#   In the LAN and over the VPN, AdGuard rewrites automation.servicestack.xyz
#   to this VM. lab118-services resolves it the same way through the tunnel.
#
#   From anywhere else the name resolves to Pangolin, which asks for SSO and
#   then comes in through the home site's Newt (the pangolin-newt VM) to this
#   VM over HTTPS, like any other LAN client. n8n's own login still applies.
#
# GitHub's deliveries come in at intake.lab118.xyz/github, and lab118-services
# passes them over the tunnel to /webhook/github here. That's the only path the
# tunnel reaches besides the health check, and the workflow behind it refuses
# anything GitHub didn't sign.
{ config, lib, pkgs, ... }:
let
  name = "automation.servicestack.xyz";
  n8n = "http://127.0.0.1:${toString config.services.n8n.environment.N8N_PORT}";

  lan = "10.0.0.0/24";
  vpn = "10.10.10.0/24";
  # lab118-services over WireGuard: GitHub's deliveries and Uptime Kuma's check.
  tunnel = "10.118.0.1";

  allow = sources: lib.concatMapStrings (s: "allow ${s};\n") sources + "deny all;\n";

  vhost = config.services.nginx.virtualHosts.${name};
  tunnelLocations = lib.attrNames (lib.filterAttrs (_: l: lib.hasInfix "allow ${tunnel};" l.extraConfig) vhost.locations);
in
{
  sops.secrets."porkbun/api-key" = { };
  sops.secrets."porkbun/secret-api-key" = { };

  security.acme = {
    acceptTerms = true;
    defaults.email = "hello@justin-arnold.com";
    certs.${name} = {
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

    virtualHosts.${name} = {
      useACMEHost = name;
      acmeRoot = null;
      forceSSL = true;
      # GitHub's deliveries, passed on by lab118-services.
      locations."= /webhook/github" = {
        proxyPass = n8n;
        extraConfig = allow [ tunnel ] + ''
          limit_except POST { deny all; }
          client_max_body_size 5m;
        '';
      };
      # Alerta's push plugin, saying an alert opened. Only an id comes in;
      # n8n reads the alert from Alerta itself.
      locations."= /webhook/alerta" = {
        proxyPass = n8n;
        extraConfig = allow [ tunnel ] + ''
          limit_except POST { deny all; }
          client_max_body_size 16k;
        '';
      };
      locations."= /healthz" = {
        proxyPass = n8n;
        extraConfig = allow [ lan vpn tunnel ];
      };
      # The UI, its API and push connection, the public API n8n-apply.py
      # uses, and the test webhooks the editor listens on.
      locations."/" = {
        proxyPass = n8n;
        proxyWebsockets = true;
        extraConfig = allow [ lan vpn ] + ''
          client_max_body_size 16m;
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
        '';
      };
    };
  };

  assertions = [
    {
      # Anything else the tunnel reached would be open to lab118-services and
      # whatever runs there.
      assertion = lib.sort lib.lessThan tunnelLocations == [ "= /healthz" "= /webhook/alerta" "= /webhook/github" ];
      message = "automation: the tunnel (${tunnel}) reaches /webhook/github, /webhook/alerta and /healthz only (got ${toString tunnelLocations}).";
    }
    {
      assertion = lib.all (path: lib.hasPrefix (allow [ tunnel ]) vhost.locations.${path}.extraConfig
        && lib.hasInfix "limit_except POST { deny all; }" vhost.locations.${path}.extraConfig)
        [ "= /webhook/github" "= /webhook/alerta" ];
      message = "automation: /webhook/github and /webhook/alerta allow the tunnel and nothing else, POST only.";
    }
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
