# How forge is reached: git.lab118.xyz, in the LAN and over the VPN only.
# AdGuard rewrites the name to this VM; there's no public record and no
# Pangolin resource. nginx serves it with a Let's Encrypt certificate
# (Porkbun DNS-01, because nothing on the Internet can reach this VM).
#
# The firewall (configuration.nix) already lets only the LAN and the VPN in
# and drops Pangolin's Newt. nginx says the same again, so either one alone
# keeps Pangolin out.
{ config, lib, pkgs, ... }:
let
  facts = import ./facts.nix;
  domain = facts.domain;
  forgejo = "http://unix:${config.services.forgejo.settings.server.HTTP_ADDR}";

  allow = sources: lib.concatMapStrings (s: "allow ${s};\n") sources + "deny all;\n";
  notViaPangolin = "deny ${facts.pangolinNewt};\n";
  access = notViaPangolin + allow facts.allowedSources;

  vhost = config.services.nginx.virtualHosts.${domain};
in
{
  sops.secrets."porkbun/api-key" = { };
  sops.secrets."porkbun/secret-api-key" = { };

  security.acme = {
    acceptTerms = true;
    defaults.email = "hello@justin-arnold.com";
    certs.${domain} = {
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

    virtualHosts.${domain} = {
      useACMEHost = domain;
      acmeRoot = null;
      forceSSL = true;
      locations."/" = {
        proxyPass = forgejo;
        extraConfig = access + ''
          # Pushes over HTTPS carry whole packs.
          client_max_body_size 512m;
          proxy_request_buffering off;
          proxy_read_timeout 10m;
        '';
      };
    };
  };

  # Forgejo's socket is mode 0666 in /run/forgejo, so nginx needs no group;
  # the forgejo group would let it read every repository.
  assertions = [
    {
      assertion = lib.attrNames vhost.locations == [ "/" ] && lib.hasPrefix access vhost.locations."/".extraConfig;
      message = "forge: ${domain} has one location, and it starts by denying Pangolin's Newt (${facts.pangolinNewt}) and then allows only ${toString facts.allowedSources}.";
    }
    {
      assertion = lib.attrNames config.services.nginx.virtualHosts == lib.sort lib.lessThan [ "_" domain ];
      message = "forge: nginx serves ${domain} and refuses everything else.";
    }
  ];
}
