# agent-watch: a read-only pass over Paperclip, within seconds of a change
# there (./paperclip-events.nix starts it) and every five minutes anyway, that
# raises and clears Alerta alerts for agents whose last run failed, issues
# stuck in progress, approvals and questions waiting on the board, open
# issues labelled change or sensitive, and budgets past their warning level,
# and, from what agent-costs writes, Claude spend nearing the month's credit
# and Claude or Jev refusing an agent for credits, from their status files,
# board-bridge or paperclip-events stalling, and from Alerta itself, alerts
# n8n should have handed to the monitor's triage and hasn't. Alerta's forwarder on
# lab118-services sends them to the phone, with a link to the issue or
# approval where there is one. See agent-watch/agent-watch.py for what each
# alert means.
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
  # Alerts about an issue or approval link to it on the board.
  spec = builtins.fromJSON (builtins.readFile ../../scripts/agents/paperclip-spec.json);
  # Which alerts n8n hands to the monitor's triage, as hosts/automation/workflows/alerta.json says it.
  eligible = (lib.findFirst (node: node.name == "Eligible?") { parameters.conditions.conditions = [ ]; }
    (lib.importJSON ../automation/workflows/alerta.json).nodes).parameters.conditions.conditions;
  rules = map (condition: condition.leftValue) eligible;
  js = list: "[${lib.concatMapStringsSep ", " (value: "'${value}'") list}]";
  harmless = entry: let pair = lib.splitString "/" entry; in
    "!($json.origin === '${lib.elemAt pair 0}' && $json.event === '${lib.elemAt pair 1}')";
  expected = [
    "${js cfg.intake.severities}.includes($json.severity)"
    "!${js cfg.intake.ignoreOrigins}.includes($json.origin)"
  ] ++ map harmless cfg.intake.harmless;
  missing = lib.filter (rule: !lib.any (lib.hasInfix rule) rules) expected;
  harmlessRules = lib.filter (lib.hasInfix "$json.event ===") rules;
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

    # The same rules as the Eligible? node in hosts/automation/workflows/alerta.json; an assertion
    # keeps the two together.
    intake = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether agent-watch raises IntakeStale for alerts n8n should have handed to the monitor's triage and hasn't.";
      };

      severities = lib.mkOption {
        type = lib.types.listOf (lib.types.enum [ "security" "critical" "major" "minor" "warning" "informational" "debug" ]);
        default = [ "critical" "major" "minor" "warning" ];
        description = "The severities n8n hands over.";
      };

      ignoreOrigins = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "agent-watch" "n8n" "send-test-alert.sh" ];
        description = "Origins n8n never hands over: the agents' own alerts, n8n's, and the end-to-end test script's.";
      };

      harmless = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[^/']+/[^/']+");
        default = [ "uptimekuma/msg" ];
        description = "Known-harmless alerts n8n never hands over, as origin/event: Kuma's test notification.";
      };

      routineTitle = lib.mkOption {
        type = lib.types.str;
        default = "Triage {{count}} lab alert(s)";
        description = "The monitor's triage routine, by its title in scripts/agents/paperclip-spec.json. Alerts waiting behind one of its issues open less than an hour aren't stale.";
      };

      staleMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
        description = "How long an alert n8n should hand over can stay open without being handed over.";
      };
    };
  };

  config = lib.mkMerge [
    {
      warnings = lib.optional (!cfg.enable)
        "agents: agent-watch is off until agent-watch/paperclip-key, alerta-key and kuma-push-url are in SOPS (agents.watch.enable).";
    }
    (lib.mkIf cfg.enable {
      assertions = lib.optionals cfg.intake.enable [ {
        assertion = missing == [ ] && lib.length harmlessRules == lib.length cfg.intake.harmless;
        message = "agents.watch.intake doesn't match the Eligible? node in hosts/automation/workflows/alerta.json; change both together. Not found there: ${builtins.toJSON missing}";
      } ];

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
          PAPERCLIP_LINK = "${config.roles.paperclip.publicUrl}/${spec.company.issuePrefix}";
          ALERTA_URL = cfg.alertaUrl;
          STUCK_AFTER_MINUTES = toString cfg.stuckAfterMinutes;
        } // lib.optionalAttrs config.agents.costs.enable {
          # Each agent's spend, from agent-costs (./agent-costs.nix).
          COSTS_DIR = "/var/lib/agent-costs";
          CLAUDE_MONTHLY_CREDITS = toString config.agents.costs.claudeMonthlyCredits;
          CLAUDE_WARN_PERCENT = toString config.agents.costs.claudeWarnPercent;
        } // lib.optionalAttrs cfg.intake.enable {
          # Whether new alerts still reach the monitor's triage through n8n's
          # alerta workflow on the automation VM.
          INTAKE_SEVERITIES = lib.concatStringsSep "," cfg.intake.severities;
          INTAKE_IGNORE_ORIGINS = lib.concatStringsSep "," cfg.intake.ignoreOrigins;
          INTAKE_HARMLESS = lib.concatStringsSep "," cfg.intake.harmless;
          INTAKE_ROUTINE = cfg.intake.routineTitle;
          INTAKE_STALE_MINUTES = toString cfg.intake.staleMinutes;
        } // lib.optionalAttrs config.agents.boardBridge.enable {
          # Whether the board's questions still reach the chat channels
          # (./board-bridge.nix).
          BRIDGE_STATUS = config.agents.boardBridge.statusFile;
          BRIDGE_STALE_MINUTES = "15";
        } // lib.optionalAttrs config.agents.events.enable {
          # Whether Paperclip's live events still reach this host
          # (./paperclip-events.nix). Its status stays fresh every minute
          # while it's connected.
          EVENTS_STATUS = config.agents.events.statusFile;
          EVENTS_STALE_MINUTES = "5";
        } // {
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
