# How the Control UI and the gateway's WebSocket are reached:
# openclaw.servicestack.xyz, with a Let's Encrypt certificate (Porkbun DNS-01,
# because nothing on the Internet can reach this VM).
#
#   In the LAN and over the VPN, AdGuard rewrites the name to this VM.
#   Paperclip on the agents VM wakes the concierge this way.
#
#   From anywhere else the name resolves to Pangolin, which asks for SSO and
#   then comes in through the home site's Newt (the pangolin-newt VM), like
#   any other LAN client. The gateway's token and device pairing still apply
#   after that.
#
# The gateway trusts this nginx as its proxy, so the client's address must be
# the only X-Forwarded-For it sees: the recommended headers would pass on
# whatever the client sent.
{ config, lib, pkgs, ... }:
let
  name = "openclaw.servicestack.xyz";
  gateway = "http://127.0.0.1:${toString config.roles.openclaw.port}";

  lan = "10.0.0.0/24";
  vpn = "10.10.10.0/24";
  # lab118-services over WireGuard: Uptime Kuma's check.
  tunnel = "10.118.0.1";

  allow = sources: lib.concatMapStrings (s: "allow ${s};\n") sources + "deny all;\n";
  headers = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
  '';

  vhosts = lib.attrNames (lib.filterAttrs (n: _: n != "_") config.services.nginx.virtualHosts);
  locations = lib.attrNames config.services.nginx.virtualHosts.${name}.locations;
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
    # Off: its X-Forwarded-For keeps what the client sent (see above).
    recommendedProxySettings = false;
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
      extraConfig = ''
        add_header Strict-Transport-Security "max-age=31536000" always;
      '';
      # Ready once the gateway has started and its agent's database is open.
      locations."= /readyz" = {
        proxyPass = gateway;
        extraConfig = allow [ lan vpn tunnel ] + headers;
      };
      # The Control UI, its API and the WebSocket share the gateway's port.
      locations."/" = {
        proxyPass = gateway;
        proxyWebsockets = true;
        extraConfig = allow [ lan vpn ] + headers + ''
          client_max_body_size 20m;
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
        '';
      };
    };
  };

  assertions = [
    {
      assertion = vhosts == [ name ] && locations == [ "/" "= /readyz" ];
      message = "openclaw: nginx serves only ${name}, at / and its readiness check (got ${toString vhosts}; ${toString locations}).";
    }
    {
      assertion = lib.all (l: lib.hasInfix "deny all;" l.extraConfig
        && lib.hasInfix "X-Forwarded-For $remote_addr;" l.extraConfig
        && !l.recommendedProxySettings) (lib.attrValues config.services.nginx.virtualHosts.${name}.locations);
      message = "openclaw: every location takes listed sources only, and passes the client's own address and no other.";
    }
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
