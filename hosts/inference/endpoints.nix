# How clients reach the model: inference.servicestack.xyz, HTTPS only, with a
# Let's Encrypt certificate (Porkbun DNS-01, because nothing on the Internet
# can reach this VM). AdGuard rewrites the name to this VM in the LAN and over
# the VPN. There's no Pangolin resource, and Newt's address is refused, so
# nothing from outside comes in that way.
#
# Every client has its own key (inference/keys/<client> in SOPS). nginx maps
# the Authorization header to the client's name from a file SOPS renders at
# activation, so no key is ever in the nix store, and drops the header before
# the request reaches llama-server. A request with no known key gets a 401.
#
# The server has `roles.inference.parallel` slots. Two connection limits keep
# one of them for voice: everything except Home Assistant shares a pool of
# `parallel - 1`, and each key gets at most 2. Over a limit nginx answers 429,
# which the agents retry.
#
# Nothing a client sends is written to disk: request bodies stay in memory,
# responses aren't buffered, and the access log has the client, status and
# timings but no bodies or query strings.
{ config, lib, pkgs, ... }:
let
  name = "inference.servicestack.xyz";
  upstream = "http://127.0.0.1:${toString config.roles.inference.port}";

  lan = "10.0.0.0/24";
  vpn = "10.10.10.0/24";
  # lab118-services over WireGuard: Uptime Kuma's check.
  tunnel = "10.118.0.1";
  # pangolin-newt: the way in from the Internet, through Pangolin. Never.
  newt = "10.0.0.72";

  # Who may call the model. Each needs inference/keys/<name> in SOPS.
  clients = [ "agents" "ha" "mac" ];
  # Exempt from the shared pool, so it always finds a free slot.
  voiceClient = "ha";
  sharedPool = config.roles.inference.parallel - 1;
  perClient = 2;

  allow = sources: "deny ${newt};\n" + lib.concatMapStrings (s: "allow ${s};\n") sources + "deny all;\n";
  keyCheck = ''
    if ($inference_client = "") {
      return 401;
    }
  '';
  limits = ''
    limit_conn inference_shared ${toString sharedPool};
    limit_conn inference_client ${toString perClient};
  '';
  proxy = ''
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Authorization "";
  '';

  mapFile = config.sops.templates."inference-clients.map".path;
  vhost = config.services.nginx.virtualHosts.${name};
  vhosts = lib.attrNames (lib.filterAttrs (n: _: n != "_") config.services.nginx.virtualHosts);
  locations = lib.attrNames vhost.locations;
  apiLocations = [ "= /v1/chat/completions" "= /v1/models" ];
  proxied = lib.filterAttrs (n: _: n != "/") vhost.locations;
  inStore = config.services.nginx.commonHttpConfig + config.services.nginx.appendHttpConfig + vhost.extraConfig
    + lib.concatMapStrings (l: l.extraConfig) (lib.attrValues vhost.locations);
in
{
  sops.secrets = {
    "porkbun/api-key" = { };
    "porkbun/secret-api-key" = { };
  } // lib.genAttrs (map (c: "inference/keys/${c}") clients) (_: { });

  # `"Bearer <key>" <client>;` per line, for the map below.
  sops.templates."inference-clients.map" = {
    content = lib.concatMapStrings
      (c: ''"Bearer ${config.sops.placeholder."inference/keys/${c}"}" ${c};'' + "\n") clients;
    owner = config.services.nginx.user;
    mode = "0400";
    reloadUnits = [ "nginx.service" ];
  };

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
    recommendedProxySettings = false;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    # The map's keys are "Bearer " and 64 hex characters, more than the
    # default bucket of 64 holds.
    mapHashBucketSize = 128;

    # At the top of the http block: nginx needs the log format, maps and
    # zones defined before the server block uses them.
    commonHttpConfig = ''
      map $http_authorization $inference_client {
        default "";
        include ${mapFile};
      }
      # Home Assistant isn't counted in the shared pool; an empty key never is.
      map $inference_client $inference_shared {
        default shared;
        "" "";
        ${voiceClient} "";
      }
      limit_conn_zone $inference_client zone=inference_client:1m;
      limit_conn_zone $inference_shared zone=inference_shared:1m;
      limit_conn_status 429;
      limit_conn_log_level warn;
      # client= is empty for a request without a known key.
      log_format inference '$time_iso8601 $remote_addr client=$inference_client $request_method $uri '
                           '$status $request_time $upstream_response_time $body_bytes_sent';
    '';

    # Requests by IP or for unknown names get nothing (no certificate, no content).
    virtualHosts."_" = {
      default = true;
      rejectSSL = true;
      locations."/".return = "444";
    };

    virtualHosts.${name} = {
      useACMEHost = name;
      acmeRoot = null;
      onlySSL = true;
      extraConfig = ''
        add_header Strict-Transport-Security "max-age=31536000" always;
        access_log /var/log/nginx/inference.log inference;
        # Bodies stay in memory: the buffer is as big as the largest body
        # allowed, so nginx never spills one to client_body_temp.
        client_max_body_size 8m;
        client_body_buffer_size 8m;
        # Answers stream through and are never written to proxy_temp.
        proxy_buffering off;
        proxy_max_temp_file_size 0;
        proxy_read_timeout 30m;
        proxy_send_timeout 30m;
      '';
      locations."= /v1/chat/completions" = {
        proxyPass = upstream;
        extraConfig = allow [ lan vpn ] + keyCheck + limits + proxy + ''
          limit_except POST { deny all; }
        '';
      };
      locations."= /v1/models" = {
        proxyPass = upstream;
        extraConfig = allow [ lan vpn ] + keyCheck + limits + proxy + ''
          limit_except GET { deny all; }
        '';
      };
      # Anything else, including nginx's own welcome page.
      locations."/".return = "404";
      # Up and loaded, for Kuma and the dashboard; no key, says nothing else.
      locations."= /health" = {
        proxyPass = upstream;
        extraConfig = allow [ lan vpn tunnel ] + proxy + ''
          limit_except GET { deny all; }
        '';
      };
    };
  };

  assertions = [
    {
      assertion = vhosts == [ name ] && lib.sort lib.lessThan locations == lib.sort lib.lessThan (apiLocations ++ [ "= /health" "/" ]);
      message = "inference: nginx serves only ${name}, at the chat API, the model list and /health (got ${toString vhosts}; ${toString locations}).";
    }
    {
      assertion = vhost.locations."/".return == "404" && vhost.locations."/".proxyPass == null
        && vhost.locations."/".root == null && vhost.locations."/".alias == null;
      message = "inference: every other path is a 404 and reaches nothing.";
    }
    {
      assertion = lib.all (l: lib.hasInfix "deny ${newt};" l.extraConfig && lib.hasInfix "deny all;" l.extraConfig
        && lib.hasInfix ''proxy_set_header Authorization "";'' l.extraConfig && !l.recommendedProxySettings)
        (lib.attrValues proxied);
      message = "inference: every location takes listed sources only, never Newt, and doesn't pass the client's key on.";
    }
    {
      assertion = lib.all (l: lib.hasInfix keyCheck vhost.locations.${l}.extraConfig
        && lib.hasInfix limits vhost.locations.${l}.extraConfig) apiLocations;
      message = "inference: the API locations need a known key and sit under the connection limits.";
    }
    {
      assertion = lib.all (s: lib.hasInfix s vhost.extraConfig) [
        "client_max_body_size 8m;" "client_body_buffer_size 8m;" "proxy_buffering off;" "proxy_max_temp_file_size 0;"
      ];
      message = "inference: request bodies stay in memory and answers aren't buffered to disk.";
    }
    {
      assertion = vhost.onlySSL && !vhost.forceSSL && !vhost.addSSL;
      message = "inference: HTTPS only, with nothing on port 80.";
    }
    {
      assertion = !(lib.hasInfix "Bearer " (lib.replaceStrings [ "$http_authorization" ] [ "" ] inStore));
      message = "inference: client keys only come from SOPS, never from the nix store.";
    }
    {
      assertion = sharedPool >= 1;
      message = "inference: needs at least two slots, so one stays free for voice.";
    }
  ];

  networking.firewall.allowedTCPPorts = [ 443 ];
}
