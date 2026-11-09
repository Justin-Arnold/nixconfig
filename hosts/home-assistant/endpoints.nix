{
  config,
  lib,
  pkgs,
  ...
}:
let
  name = "home-assistant.servicestack.xyz";
  access = ''
    deny 10.0.0.72;
    allow 10.0.0.0/24;
    allow 10.10.10.0/24;
    deny all;
  '';
  vhost = config.services.nginx.virtualHosts.${name};
in
{
  sops.secrets."porkbun/api-key" = { };
  sops.secrets."porkbun/secret-api-key" = { };
  security.acme = {
    acceptTerms = true;
    defaults.email = "hello@justin-arnold.com";
    certs.${name} = {
      dnsProvider = "porkbun";
      dnsResolver = "1.1.1.1:53";
      credentialFiles = {
        PORKBUN_API_KEY_FILE = config.sops.secrets."porkbun/api-key".path;
        PORKBUN_SECRET_API_KEY_FILE = config.sops.secrets."porkbun/secret-api-key".path;
      };
      environmentFile = pkgs.writeText "home-assistant-acme.env" ''
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
    virtualHosts."_" = {
      default = true;
      rejectSSL = true;
      locations."/".return = "444";
    };
    virtualHosts.${name} = {
      useACMEHost = name;
      acmeRoot = null;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:8123";
        proxyWebsockets = true;
        extraConfig = access + ''
          client_max_body_size 64m;
          proxy_read_timeout 1h;
        '';
      };
    };
  };
  networking.firewall.allowedTCPPorts = [
    80
    443
  ];
  assertions = [
    {
      assertion =
        lib.attrNames vhost.locations == [ "/" ]
        && lib.hasPrefix access vhost.locations."/".extraConfig
        && vhost.locations."/".proxyPass == "http://127.0.0.1:8123"
        && vhost.locations."/".proxyWebsockets;
      message = "home-assistant: HTTPS proxy must remain LAN/VPN-only, deny Newt, with no extra locations.";
    }
    {
      assertion =
        vhost.forceSSL
        && vhost.useACMEHost == name
        && config.services.nginx.virtualHosts."_".rejectSSL
        && config.services.nginx.virtualHosts."_".locations."/".return == "444";
      message = "home-assistant: TLS and unknown-host rejection must remain enabled.";
    }
  ];
}
