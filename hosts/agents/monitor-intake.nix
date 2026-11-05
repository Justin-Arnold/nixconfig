# monitor-intake: every 2 minutes, new alerts in Alerta go to the monitor
# agent as one triage issue, through its "Triage lab alerts" routine in
# Paperclip. See monitor-intake/monitor-intake.py.
#
# It reads Alerta with the read-only key the lab tools use, and starts the
# routine with the monitor's own Paperclip key, which can run only the
# monitor's routines. It runs as its own user, not the monitor's, so it
# can't read the agent's logins or sessions, and it reaches only Paperclip
# on loopback and Alerta. Nothing reaches Paperclip from outside for this:
# its public routine webhooks stay closed (nginx/paperclip-guard.conf).
{ config, lib, pkgs, ... }:
let
  cfg = config.agents.monitorIntake;
  hermes = config.roles.hermesAgents;
  monitor = hermes.instances.monitor or null;
  alerta = hermes.observe.alerta;
  ready = monitor != null && monitor.secrets ? PAPERCLIP_AGENT_KEY && alerta != null;
  alertaHost = lib.head (lib.splitString ":" (lib.head (lib.splitString "/" (lib.last (lib.splitString "://" alerta.url)))));
  stateDir = "/var/lib/monitor-intake";
in
{
  options.agents.monitorIntake = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether new Alerta alerts go to the monitor agent to triage.";
    };

    severities = lib.mkOption {
      type = lib.types.listOf (lib.types.enum [ "security" "critical" "major" "minor" "warning" "informational" "debug" ]);
      default = [ "critical" "major" "minor" "warning" ];
      description = "Which alerts the monitor triages.";
    };

    routineTitle = lib.mkOption {
      type = lib.types.str;
      default = "Triage {{count}} lab alert(s)";
      description = "The monitor's triage routine, by its title in scripts/agents/paperclip-spec.json.";
    };

    dailyLimit = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "At most this many triage runs a UTC day; past it, new alerts wait and agent-watch says so.";
    };

    statusFile = lib.mkOption {
      type = lib.types.str;
      default = "${stateDir}/status.json";
      readOnly = true;
      description = "When a pass last worked and what last went wrong, for agent-watch.";
    };

    active = lib.mkOption {
      type = lib.types.bool;
      default = cfg.enable && ready;
      readOnly = true;
      description = "Whether the intake is running: enabled, with the monitor's Paperclip key and Alerta on.";
    };
  };

  config = lib.mkMerge [
    {
      warnings = lib.optional (cfg.enable && !ready)
        "agents: monitor-intake is off until the monitor has its Paperclip key and the lab tools have Alerta.";
    }
    (lib.mkIf cfg.active {
      assertions = [ {
        assertion = builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" alertaHost != null;
        message = "agents: monitor-intake reaches Alerta by IP address only (its unit allows that one address).";
      } ];

      users.users.monitor-intake = {
        isSystemUser = true;
        group = "monitor-intake";
      };
      users.groups.monitor-intake = { };

      systemd.tmpfiles.rules = [ "d ${stateDir} 0755 monitor-intake monitor-intake - -" ];

      systemd.services.monitor-intake = {
        description = "Hand new Alerta alerts to the monitor agent";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" "podman-paperclip.service" ];
        environment = {
          PAPERCLIP_URL = "http://127.0.0.1:${toString config.roles.paperclip.port}";
          ALERTA_URL = alerta.url;
          STATE_DIR = stateDir;
          SEVERITIES = lib.concatStringsSep "," cfg.severities;
          # agent-watch's alerts are about the agents; triaging them could loop.
          IGNORE_ORIGINS = "agent-watch";
          ROUTINE_TITLE = cfg.routineTitle;
          DAILY_LIMIT = toString cfg.dailyLimit;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe pkgs.python3} -I ${./monitor-intake/monitor-intake.py}";
          TimeoutStartSec = "2min";
          User = "monitor-intake";
          Group = "monitor-intake";
          LoadCredential = [
            "paperclip-key:${config.sops.secrets.${monitor.secrets.PAPERCLIP_AGENT_KEY}.path}"
            "alerta-key:${config.sops.secrets.${alerta.secret}.path}"
          ];
          UMask = "0022";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ stateDir ];
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
          IPAddressAllow = [ "localhost" alertaHost ];
          IPAddressDeny = [ "any" ];
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

      systemd.timers.monitor-intake = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/2";
          RandomizedDelaySec = "15s";
        };
      };
    })
  ];
}
