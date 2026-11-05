# agent-watch: every five minutes, a read-only pass over Paperclip that
# raises and clears Alerta alerts for agents whose last run failed, issues
# stuck in progress, approvals waiting on the board, open issues labelled
# change or sensitive, and budgets past their warning level. Alerta's
# forwarder on lab118-services sends them to the phone. See
# agent-watch/agent-watch.py for what each alert means.
#
# It reads with its own key on the researcher, the least privileged agent on
# this host, posts to Alerta over the lab tunnel, and reports each good pass
# to a Kuma push monitor, so Kuma notices when it stops. It runs as a
# throwaway user with its three secrets as systemd credentials; nothing
# else on the host can read them.
{ config, lib, pkgs, ... }:
let
  cfg = config.agents.watch;
  secret = name: config.sops.secrets."agent-watch/${name}".path;
in
{
  options.agents.watch = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether agent-watch runs. Its three secrets have to be in SOPS first.";
    };

    alertaUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://10.118.0.1:5000";
      description = "Alerta's API on lab118-services, over the lab tunnel.";
    };

    stuckAfterMinutes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "How long an issue can sit in progress with no run and no activity before it's stuck.";
    };
  };

  config = lib.mkMerge [
    {
      warnings = lib.optional (!cfg.enable)
        "agents: agent-watch is off until agent-watch/paperclip-key, alerta-key and kuma-push-url are in SOPS (agents.watch.enable).";
    }
    (lib.mkIf cfg.enable {
      sops.secrets = {
        "agent-watch/paperclip-key" = { };
        "agent-watch/alerta-key" = { };
        "agent-watch/kuma-push-url" = { };
      };

      systemd.services.agent-watch = {
        description = "Raise and clear Alerta alerts from Paperclip";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" "podman-paperclip.service" ];
        environment = {
          PAPERCLIP_URL = "http://127.0.0.1:${toString config.roles.paperclip.port}";
          ALERTA_URL = cfg.alertaUrl;
          STUCK_AFTER_MINUTES = toString cfg.stuckAfterMinutes;
          # For the HTTPS push to Kuma; Python doesn't find the bundle itself.
          SSL_CERT_FILE = config.security.pki.caBundle;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.python3} -I ${./agent-watch/agent-watch.py}";
          TimeoutStartSec = "3min";
          DynamicUser = true;
          LoadCredential = [
            "paperclip-key:${secret "paperclip-key"}"
            "alerta-key:${secret "alerta-key"}"
            "kuma-push-url:${secret "kuma-push-url"}"
          ];
          UMask = "0077";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" "~@privileged" ];
          CapabilityBoundingSet = "";
        };
      };

      systemd.timers.agent-watch = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/5";
          RandomizedDelaySec = "30s";
        };
      };
    })
  ];
}
