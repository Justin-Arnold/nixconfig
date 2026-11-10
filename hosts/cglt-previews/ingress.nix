# Traefik on port 80, the one way into the previews and the ops tools.
#
# The Pangolin VPS holds the *.preview.commongoodlt.dev wildcard certificate
# and a hand-written Traefik route that sends those names through the home
# site's Newt to this VM over plain HTTP (docs/cglt-previews/REFERENCE.md).
# Traefik here trusts X-Forwarded-* from the Newt alone, so the apps see
# https and don't redirect to http.
#
# Previews route themselves with Docker labels: a container is routed only if
# it says traefik.enable=true, and Traefik reaches it on the preview-edge
# network. The ops tools are routes in the file provider below, to their
# loopback ports.
{ config, lib, pkgs, ... }:
let
  facts = import ./facts.nix;
  cfg = config.services.traefik;
  static = cfg.staticConfigOptions;
  web = static.entryPoints.web or { };
  dockerProvider = static.providers.docker or { };
  routers = cfg.dynamicConfigOptions.http.routers or { };
  services = cfg.dynamicConfigOptions.http.services or { };
  docker = "${config.virtualisation.docker.package}/bin/docker";

  opsRoute = name: port: middlewares: {
    routers.${name} = {
      rule = "Host(`${name}.${facts.domain}`)";
      entryPoints = [ "web" ];
      service = name;
      inherit middlewares;
    };
    services.${name}.loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
  };
in
{
  # htpasswd lines (bcrypt) for the gate in front of Dockhand, which starts
  # with its own login switched off and can't be told otherwise.
  sops.secrets."traefik/ops-users" = {
    owner = "traefik";
    restartUnits = [ "traefik.service" ];
  };

  services.traefik = {
    enable = true;

    staticConfigOptions = {
      entryPoints.web = {
        address = ":80";
        forwardedHeaders.trustedIPs = [ facts.newt ];
      };

      providers.docker = {
        endpoint = "unix:///var/run/docker.sock";
        exposedByDefault = false;
        network = facts.edgeNetwork;
        watch = true;
      };

      log.level = "INFO";
      accessLog = { };
      global = {
        checkNewVersion = false;
        sendAnonymousUsage = false;
      };
    };

    dynamicConfigOptions.http = lib.foldl lib.recursiveUpdate { } [
      {
        middlewares = {
          # Previews reference it as preview-noindex@file.
          preview-noindex.headers.customResponseHeaders."X-Robots-Tag" = "noindex, nofollow";
          ops-auth.basicAuth = {
            usersFile = config.sops.secrets."traefik/ops-users".path;
            realm = "cglt-previews";
            removeHeader = true;
          };
        };
      }
      (opsRoute "dockhand" facts.ports.dockhand [ "ops-auth" "preview-noindex" ])
      # File Browser and Mailpit have their own logins (ops.nix).
      (opsRoute "files" facts.ports.filebrowser [ "preview-noindex" ])
      (opsRoute "mail" facts.ports.mailpit [ "preview-noindex" ])
    ];
  };

  # The Docker provider reads the socket.
  users.users.traefik.extraGroups = [ "docker" ];
  systemd.services.traefik = {
    after = [ "docker.service" "preview-edge-network.service" ];
    wants = [ "preview-edge-network.service" ];
  };

  # The network previews join to be routed (external in their compose files).
  # Mailpit is on it too, as `mailpit`.
  systemd.services.preview-edge-network = {
    description = "Create the ${facts.edgeNetwork} Docker network";
    wantedBy = [ "multi-user.target" ];
    requires = [ "docker.service" ];
    after = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ! ${docker} network inspect ${facts.edgeNetwork} >/dev/null 2>&1; then
        ${docker} network create --driver bridge ${facts.edgeNetwork}
      fi
    '';
  };

  assertions = [
    {
      assertion = lib.attrNames (static.entryPoints or { }) == [ "web" ] && (web.address or null) == ":80"
        && (web.forwardedHeaders.trustedIPs or [ ]) == [ facts.newt ]
        && !(web.forwardedHeaders.insecure or false)
        && !(web ? proxyProtocol);
      message = "cglt-previews: Traefik listens on :80 only and trusts forwarded headers from the Newt (${facts.newt}) alone.";
    }
    {
      assertion = !(static ? api) && !(static ? ping) && !(static ? metrics);
      message = "cglt-previews: no Traefik API, dashboard, ping or metrics; they'd add an entrypoint.";
    }
    {
      assertion = (dockerProvider.exposedByDefault or true) == false && (dockerProvider.network or null) == facts.edgeNetwork
        && lib.attrNames (static.providers or { }) == [ "docker" ];
      message = "cglt-previews: Traefik routes only containers labelled traefik.enable=true, on ${facts.edgeNetwork}, plus its own file routes.";
    }
    {
      assertion = lib.sort lib.lessThan (lib.attrNames routers) == [ "dockhand" "files" "mail" ]
        && lib.elem "ops-auth" (routers.dockhand.middlewares or [ ])
        && lib.all (s: lib.all (srv: lib.hasPrefix "http://127.0.0.1:" (srv.url or "")) (s.loadBalancer.servers or [ ])) (lib.attrValues services)
        && lib.all (s: s ? loadBalancer) (lib.attrValues services);
      message = "cglt-previews: the file provider routes dockhand., files. and mail. to loopback only, Dockhand behind ops-auth.";
    }
  ];
}
