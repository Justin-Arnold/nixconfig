# Doppler project `lab118-services`, config `prd`: which keys exist and which
# runtime files they become. Shared by the host configuration and the
# doppler-secrets flake check, so the tests exercise the real layout.
#
# Every field is spelled out (no module defaults) because the check builds the
# spec without evaluating NixOS.
let
  file = attrs: {
    format = "raw";
    key = null;
    vars = { };
    static = { };
    owner = "root";
    group = "root";
    mode = "0400";
    restartServices = [ ];
  } // attrs;
in
{
  outputs = {
    alertaSecretKey = file {
      path = "alerta/secret-key";
      key = "ALERTA_SECRET_KEY";
      owner = "alerta";
      group = "alerta";
      restartServices = [ "alerta" ];
    };
    alertaAdminUser = file {
      path = "alerta/admin-user";
      key = "ALERTA_ADMIN_USER";
      owner = "alerta";
      group = "alerta";
      restartServices = [ "alerta-bootstrap" "alerta" ];
    };
    alertaAdminPassword = file {
      path = "alerta/admin-password";
      key = "ALERTA_ADMIN_PASSWORD";
      owner = "alerta";
      group = "alerta";
      restartServices = [ "alerta-bootstrap" ];
    };
    alertaApiKey = file {
      path = "alerta/api-key";
      key = "ALERTA_API_KEY";
      owner = "alerta";
      group = "alerta";
      # The forwarder re-reads the key on every poll.
      restartServices = [ "alerta-bootstrap" ];
    };
    appriseConfig = file {
      path = "apprise/homelab-alerts.cfg";
      key = "APPRISE_CONFIG";
      # Read inside the Apprise container as uid 1000 (same as the old host).
      owner = "1000";
      # The bind mount pins the old inode, so the container must restart.
      restartServices = [ "docker-apprise" ];
    };
    ntfyEnv = file {
      path = "ntfy.env";
      format = "systemd-env";
      vars = {
        NTFY_AUTH_USERS = "NTFY_AUTH_USERS";
        NTFY_AUTH_TOKENS = "NTFY_AUTH_TOKENS";
      };
      static.NTFY_AUTH_ACCESS = "apprise:homelab-alerts:write-only";
      restartServices = [ "ntfy-sh" ];
    };
    nodeRedEnv = file {
      path = "node-red.env";
      format = "docker-env";
      vars.ALERTA_API_KEY = "ALERTA_API_KEY";
      restartServices = [ "docker-node-red" ];
    };
    newtEnv = file {
      path = "newt.env";
      format = "systemd-env";
      vars = {
        NEWT_ID = "NEWT_ID";
        NEWT_SECRET = "NEWT_SECRET";
      };
      restartServices = [ "newt" ];
    };
  };

  # Light checks that catch truncated or mis-pasted values without being so
  # strict that a valid value is refused.
  validators = {
    APPRISE_CONFIG = "://";
    NTFY_AUTH_USERS = "^[^:,\\s]+:[^,\\s]+:(admin|user)(,[^:,\\s]+:[^,\\s]+:(admin|user))*$";
    NTFY_AUTH_TOKENS = "^[^:,\\s]+:tk_[A-Za-z0-9]+(:[^,]*)?(,[^:,\\s]+:tk_[A-Za-z0-9]+(:[^,]*)?)*$";
    ALERTA_API_KEY = "^\\S+$";
    NEWT_ID = "^\\S+$";
    NEWT_SECRET = "^\\S+$";
  };
}
