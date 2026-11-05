# How Paperclip is reached. The name works two ways, and both end at the same
# nginx server block with a Let's Encrypt certificate (Porkbun DNS-01,
# because nothing on the Internet can reach this VM):
#
#   In the LAN and over the VPN, AdGuard rewrites paperclip.servicestack.xyz
#   to this VM. Agents on other hosts (openclaw) use this path for the API,
#   and it keeps working when the WAN is down.
#
#   From anywhere else the name resolves to Pangolin, which asks for SSO and
#   then comes in through the home site's Newt (the pangolin-newt VM) to this
#   VM over HTTPS, like any other LAN client. Paperclip's own login still
#   applies after that.
#
# Paperclip's MCP endpoint and its public routine webhooks are blocked in
# every server block that reaches Paperclip (nginx/paperclip-guard.conf).
{ config, lib, pkgs, ... }:
let
  paperclipName = "paperclip.servicestack.xyz";
  paperclip = "http://127.0.0.1:${toString config.roles.paperclip.port}";

  lan = "10.0.0.0/24";
  vpn = "10.10.10.0/24";
  # lab118-services over WireGuard: Uptime Kuma's checks.
  tunnel = "10.118.0.1";

  allow = sources: lib.concatMapStrings (s: "allow ${s};\n") sources + "deny all;\n";
  guard = "include ${./nginx/paperclip-guard.conf};\n";

  # Every server block that can reach Paperclip must include the guard and
  # may only have these locations, so nothing can match a request before the
  # guard does.
  upstreamPort = ":${toString config.roles.paperclip.port}";
  reachesPaperclip = vh: lib.any (l: l.proxyPass != null && lib.hasSuffix upstreamPort l.proxyPass) (lib.attrValues vh.locations);
  paperclipVhosts = lib.filterAttrs (_: reachesPaperclip) config.services.nginx.virtualHosts;
  unguardedVhosts = lib.attrNames (lib.filterAttrs (_: vh: !(lib.hasInfix "paperclip-guard.conf" vh.extraConfig)) paperclipVhosts);
  extraLocations = lib.concatLists (lib.mapAttrsToList
    (name: vh: map (l: "${name} ${l}") (lib.subtractLists [ "/" "= /api/health" ] (lib.attrNames vh.locations)))
    paperclipVhosts);
in
{
  sops.secrets."porkbun/api-key" = { };
  sops.secrets."porkbun/secret-api-key" = { };

  security.acme = {
    acceptTerms = true;
    defaults.email = "hello@justin-arnold.com";
    certs.${paperclipName} = {
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

    virtualHosts.${paperclipName} = {
      useACMEHost = paperclipName;
      acmeRoot = null;
      forceSSL = true;
      extraConfig = guard;
      locations."= /api/health" = {
        proxyPass = paperclip;
        extraConfig = allow [ lan vpn tunnel ];
      };
      # The UI, the API and the live-update WebSocket.
      locations."/" = {
        proxyPass = paperclip;
        proxyWebsockets = true;
        extraConfig = allow [ lan vpn ] + ''
          client_max_body_size 50m;
          proxy_read_timeout 1h;
          proxy_send_timeout 1h;
        '';
      };
    };
  };

  assertions = [
    {
      assertion = paperclipVhosts != { } && unguardedVhosts == [ ];
      message = "agents: nginx server blocks reaching Paperclip without the guard: ${toString unguardedVhosts}.";
    }
    {
      assertion = extraLocations == [ ];
      message = "agents: locations that could match before the Paperclip guard: ${lib.concatStringsSep ", " extraLocations}.";
    }
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
