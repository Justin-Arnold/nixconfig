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
#
# The one exception is paperclip-triggers.servicestack.xyz, made for a single
# sender: n8n on the automation VM, which starts routines through their
# webhooks. That name reaches one path, a trigger's fire URL, with POST only
# and from that VM's address only, and every trigger is signed with bearer
# (paperclip-apply.py refuses anything else), so n8n's secret is needed too.
{ config, lib, pkgs, ... }:
let
  paperclipName = "paperclip.servicestack.xyz";
  triggersName = "paperclip-triggers.servicestack.xyz";
  paperclip = "http://127.0.0.1:${toString config.roles.paperclip.port}";

  # n8n's VM.
  automationVm = "10.0.0.155";
  # A trigger's fire URL and nothing else: 24 hex digits are Paperclip's
  # publicId. nginx matches the decoded, normalised path, and the path passed
  # on is rebuilt from the captured id alone, so nothing else in the request
  # line (a query string, or a CR/LF that gixy rightly worries about with
  # $uri) reaches Paperclip. The quotes are nginx's: a regex with braces in
  # it must be quoted.
  triggerLocation = ''~ "^/api/routine-triggers/public/(?<trigger>[0-9a-f]{24})/fire$"'';
  triggerUpstream = "${paperclip}/api/routine-triggers/public/$trigger/fire";
  triggerAccess = allow [ automationVm ] + ''
    limit_except POST { deny all; }
    client_max_body_size 64k;
  '';

  lan = "10.0.0.0/24";
  vpn = "10.10.10.0/24";
  # lab118-services over WireGuard: Uptime Kuma's checks.
  tunnel = "10.118.0.1";

  allow = sources: lib.concatMapStrings (s: "allow ${s};\n") sources + "deny all;\n";
  guard = "include ${./nginx/paperclip-guard.conf};\n";

  # Every server block that can reach Paperclip, except the triggers one,
  # must include the guard and may only have these locations, so nothing can
  # match a request before the guard does. A proxyPass counts wherever the
  # upstream appears in it, so one with a path or a variable after it does too.
  upstream = "127.0.0.1:${toString config.roles.paperclip.port}";
  reachesPaperclip = vh: lib.any (l: l.proxyPass != null && lib.hasInfix upstream l.proxyPass) (lib.attrValues vh.locations);
  paperclipVhosts = lib.filterAttrs (name: vh: name != triggersName && reachesPaperclip vh) config.services.nginx.virtualHosts;
  triggers = config.services.nginx.virtualHosts.${triggersName};
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
    certs = lib.genAttrs [ paperclipName triggersName ] (_: {
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
    });
  };

  # Paperclip refuses names it doesn't know, and nginx passes this one on.
  roles.paperclip.allowedHostnames = [ triggersName ];

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

    virtualHosts.${triggersName} = {
      useACMEHost = triggersName;
      acmeRoot = null;
      forceSSL = true;
      locations.${triggerLocation} = {
        proxyPass = triggerUpstream;
        extraConfig = triggerAccess;
      };
      locations."/".return = "404";
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
    {
      assertion = lib.attrNames triggers.locations == lib.sort lib.lessThan [ triggerLocation "/" ]
        && triggers.locations."/".proxyPass == null && triggers.locations."/".return == "404"
        && triggers.locations.${triggerLocation}.proxyPass == triggerUpstream
        && triggers.locations.${triggerLocation}.extraConfig == triggerAccess
        && triggers.extraConfig == "";
      message = "agents: ${triggersName} reaches Paperclip only at a trigger's fire URL, POST only, from ${automationVm} only.";
    }
  ];

  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
