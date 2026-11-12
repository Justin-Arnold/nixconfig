# The ops tools, each a pinned container on a loopback port that Traefik
# publishes (ingress.nix). Each answers only Warpgate, where people open it at
# <name>.access.commongoodlt.dev:
#
#   dockhand  Dockhand: live logs, a shell in any container, compose stacks.
#   files     File Browser on /srv/previews/config, where each preview's
#             local-overrides.php lives.
#   mail      Mailpit, which every preview sends its mail to (mailpit:1025 on
#             preview-edge).
#
# None has a login of its own. Warpgate gives each person their own login
# with MFA and logs every request; its previews-ops role is the one thing to
# grant or take away, so give it to developers only. The tools' own logins
# would only be shared accounts on top: Dockhand's free edition makes every
# account an admin and audits nothing. Dockhand still warns "Unsecured
# exposure" at startup, because it can't see Warpgate.
#
# To move an image: look up the new tag's digest
# (`curl -s https://hub.docker.com/v2/repositories/<repo>/tags/<tag> | jq -r .digest`)
# and change both here.
{ config, lib, ... }:
let
  facts = import ./facts.nix;
  root = facts.previewsRoot;
  containers = config.virtualisation.oci-containers.containers;
  loopback = port: "127.0.0.1:${toString port}";
  docker = "${config.virtualisation.docker.package}/bin/docker";
in
{
  sops.secrets."dockhand/encryption-key".restartUnits = [ "docker-dockhand.service" ];

  sops.templates."dockhand.env".content = ''
    ENCRYPTION_KEY=${config.sops.placeholder."dockhand/encryption-key"}
  '';

  systemd.tmpfiles.rules = [
    "d /var/lib/dockhand 0750 root root -"
    "d /var/lib/filebrowser 0750 33 33 -"
    "d /var/lib/mailpit 0750 root root -"
  ];

  virtualisation.oci-containers.containers = {
    dockhand = {
      image = "fnsys/dockhand:v1.0.57@sha256:4fd64d32728c99e5caf39b952a17d85448ee0b8ae76e0961f719ba2e19013988";
      ports = [ "${loopback facts.ports.dockhand}:3000" ];
      volumes = [
        "/var/run/docker.sock:/var/run/docker.sock"
        "/var/lib/dockhand:/var/lib/dockhand"
        # Same path inside, so the stacks deploy jobs write resolve the
        # relative paths in their compose files the same way.
        "${root}/stacks:${root}/stacks"
      ];
      environment = {
        DATA_DIR = "/var/lib/dockhand";
        HOST_DATA_DIR = "/var/lib/dockhand";
        # Where browsers have it open. Warpgate passes their Origin header on.
        ORIGIN = "https://dockhand.${facts.warpgate.domain}";
        # Only Traefik reaches it, and Traefik passes on what the Newt said.
        TRUST_FORWARDED_HEADERS = "true";
        COOKIE_SECURE = "true";
      };
      environmentFiles = [ config.sops.templates."dockhand.env".path ];
    };

    filebrowser = {
      # File Browser's repository was archived on 2026-09-01: no more
      # releases or security fixes. This is its last release.
      image = "filebrowser/filebrowser:v2.63.23@sha256:a469ea076d4a1b4b1d86a41d130f2f536cd9da996a2b1fb39c0d7635f9d89b9a";
      # www-data in the PHP images, which own the config files.
      user = "33:33";
      ports = [ "${loopback facts.ports.filebrowser}:8080" ];
      volumes = [
        "${root}/config:/srv"
        "/var/lib/filebrowser:/database"
      ];
      # The binary directly, with its settings as flags, instead of the
      # image's init script and its settings file.
      entrypoint = "/bin/tini";
      cmd = [
        "--"
        "/bin/filebrowser"
        "--address=0.0.0.0"
        "--port=8080"
        "--root=/srv"
        "--database=/database/filebrowser.db"
        # The command runner runs shell commands as uid 33 in the container.
        "--disableExec=true"
        # No login: everyone works as its first user, admin. This sets it
        # when File Browser creates its database; the preStart below sets it
        # on an existing one.
        "--noauth"
      ];
      # The image's check reads the settings file this setup doesn't use.
      extraOptions = [ "--no-healthcheck" ];
    };

    mailpit = {
      image = "axllent/mailpit:v1.33.1@sha256:aef2aacc11f075ec0fb6874275ee4a421e688e11a96ebb296134d1735c7761ce";
      ports = [ "${loopback facts.ports.mailpit}:8025" ];
      networks = [ facts.edgeNetwork ];
      extraOptions = [ "--network-alias=mailpit" ];
      volumes = [ "/var/lib/mailpit:/data" ];
      environment = {
        MP_SMTP_BIND_ADDR = "0.0.0.0:1025";
        MP_UI_BIND_ADDR = "0.0.0.0:8025";
        # Previews send with whatever their instance config says: any sender,
        # any SMTP login or none, no TLS.
        MP_SMTP_AUTH_ACCEPT_ANY = "true";
        MP_SMTP_AUTH_ALLOW_INSECURE = "true";
        MP_DATABASE = "/data/mailpit.db";
        MP_MAX_MESSAGES = "5000";
      };
    };
  };

  # File Browser keeps its login method in its database, and --noauth only
  # applies when it creates one. Set it on the existing database before each
  # start, once no container holds the database's lock.
  systemd.services.docker-filebrowser.preStart = lib.mkAfter ''
    ${docker} rm -f filebrowser >/dev/null 2>&1 || true
    if [ -e /var/lib/filebrowser/filebrowser.db ]; then
      ${docker} run --rm --network none --user 33:33 \
        -v /var/lib/filebrowser:/database --entrypoint /bin/filebrowser \
        ${containers.filebrowser.image} \
        config set --auth.method=noauth --database /database/filebrowser.db >/dev/null
    fi
  '';

  systemd.services.docker-mailpit = {
    requires = [ "preview-edge-network.service" ];
    after = [ "preview-edge-network.service" ];
  };

  assertions = [
    {
      assertion = lib.all (c: lib.all (lib.hasPrefix "127.0.0.1:") c.ports) (lib.attrValues containers);
      message = "cglt-previews: every container the host defines publishes on 127.0.0.1 only; Traefik is the way in.";
    }
    {
      assertion = lib.all (c: builtins.match ".*@sha256:[0-9a-f]{64}" c.image != null) (lib.attrValues containers);
      message = "cglt-previews: every container image is pinned by digest.";
    }
    {
      assertion = lib.elem "--disableExec=true" containers.filebrowser.cmd && containers.filebrowser.user == "33:33";
      message = "cglt-previews: File Browser runs as uid 33 with its command runner off.";
    }
  ];
}
