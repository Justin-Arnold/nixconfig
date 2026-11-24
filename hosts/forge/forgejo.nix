# Forgejo (services.forgejo, the LTS release nixpkgs ships), on SQLite. It
# listens on a Unix socket only; nginx publishes it (./endpoints.nix). Git
# over SSH goes through the system's OpenSSH as the forgejo user, whose
# authorized_keys Forgejo writes with each key pinned to `forgejo serv`.
#
# Nobody can sign up: Justin creates his admin account by hand and every
# account needs a second factor (TOTP or a security key). Every repository is
# private. Mirrors, migrations, Actions, packages and LFS are off, and the
# service itself can't open a connection beyond loopback, so nothing in it can
# copy a repository off this host. See docs/forge/REFERENCE.md.
{ config, lib, pkgs, ... }:
let
  facts = import ./facts.nix;
  cfg = config.services.forgejo;
  svc = config.systemd.services.forgejo.serviceConfig;
  s = cfg.settings;

  # `sudo forge-admin <args>`: `forgejo admin` as the service's user, with
  # its config, e.g. `sudo forge-admin user list`.
  forgeAdmin = pkgs.writeShellApplication {
    name = "forge-admin";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      if [[ $EUID -ne 0 ]]; then
        echo "forge-admin: run it with sudo" >&2
        exit 1
      fi
      cd ${cfg.stateDir}
      exec runuser -u ${cfg.user} -- env HOME=${cfg.stateDir} FORGEJO_WORK_DIR=${cfg.stateDir} \
        FORGEJO_CUSTOM=${cfg.customDir} ${lib.getExe cfg.package} admin "$@"
    '';
  };
in
{
  environment.systemPackages = [ forgeAdmin ];

  # A fixed UID instead of an allocated one, so restored files and backups
  # keep a predictable owner.
  users.groups.forgejo.gid = 3000;
  users.users.forgejo.uid = 3000;

  services.forgejo = {
    enable = true;
    database.type = "sqlite3";
    lfs.enable = false;

    settings = {
      DEFAULT.APP_NAME = "forge";

      server = {
        DOMAIN = facts.domain;
        ROOT_URL = "https://${facts.domain}/";
        # The socket is /run/forgejo/forgejo.sock (the module's default).
        PROTOCOL = "http+unix";
        SSH_DOMAIN = facts.domain;
        SSH_PORT = facts.sshPort;
        START_SSH_SERVER = false;
        # No Gravatar, no CDN: every page is served from here.
        OFFLINE_MODE = true;
        LANDING_PAGE = "login";
      };

      service = {
        DISABLE_REGISTRATION = true;
        REQUIRE_SIGNIN_VIEW = true;
        DEFAULT_KEEP_EMAIL_PRIVATE = true;
        DEFAULT_ALLOW_CREATE_ORGANIZATION = false;
        ENABLE_NOTIFY_MAIL = false;
      };

      security = {
        # Every account signs in with a password and a second factor.
        GLOBAL_TWO_FACTOR_REQUIREMENT = "all";
      };

      session.COOKIE_SECURE = true;

      repository = {
        DEFAULT_PRIVATE = "private";
        FORCE_PRIVATE = true;
        # Importing from another forge would need the network the service
        # doesn't have; push instead.
        DISABLE_MIGRATIONS = true;
        ENABLE_PUSH_CREATE_USER = false;
        ENABLE_PUSH_CREATE_ORG = false;
      };

      admin.DISABLE_REGULAR_ORG_CREATION = true;
      openid = {
        ENABLE_OPENID_SIGNIN = false;
        ENABLE_OPENID_SIGNUP = false;
      };
      # Forgejo as an OAuth2 provider for other apps.
      oauth2.ENABLED = false;
      # Pull and push mirrors, both ways.
      mirror.ENABLED = false;
      actions.ENABLED = false;
      packages.ENABLED = false;
      federation.ENABLED = false;
      "cron.update_checker".ENABLED = false;
      api.ENABLE_SWAGGER = false;
    };
  };

  systemd.services.forgejo = {
    # The module only writes authorized_keys again when the file exists, so
    # a restore onto a fresh VM would leave every SSH key out.
    preStart = lib.mkAfter ''
      ${lib.getExe cfg.package} admin regenerate keys
    '';
    serviceConfig = {
      # Nothing it does needs the network: nginx and `forgejo serv` reach it on
      # its socket.
      IPAddressAllow = [ "localhost" ];
      IPAddressDeny = [ "any" ];
    };
  };

  assertions = [
    {
      assertion = s.server.PROTOCOL == "http+unix" && !(s.server.START_SSH_SERVER or false);
      message = "forge: Forgejo listens on its Unix socket only, and git over SSH goes through OpenSSH.";
    }
    {
      assertion = svc.IPAddressDeny == [ "any" ] && svc.IPAddressAllow == [ "localhost" ];
      message = "forge: forgejo.service reaches loopback only, so no webhook, mirror or migration can carry a repository off this host.";
    }
    {
      assertion = s.service.DISABLE_REGISTRATION && s.service.REQUIRE_SIGNIN_VIEW
        && s.security.GLOBAL_TWO_FACTOR_REQUIREMENT == "all" && s.repository.FORCE_PRIVATE;
      message = "forge: no sign-up, nothing visible signed out, a second factor for every account, every repository private.";
    }
    {
      assertion = !s.mirror.ENABLED && !s.actions.ENABLED && !s.packages.ENABLED && !cfg.lfs.enable;
      message = "forge: no mirrors, no Actions, no packages, no LFS.";
    }
  ];
}
