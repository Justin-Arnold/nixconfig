# lab-health: at 07:00 New York time, the lab's morning check in code. It
# reads Proxmox, Beszel, Kuma and Alerta with the lab MCP server's own
# functions, turns what's wrong into fixed codes, and only when there are
# some runs the monitor's "Look into {{count}} lab finding(s)" routine with
# them. A quiet morning runs no model. See lab-health/lab-health.py.
#
# It reads with the agents' observe credentials and starts the routine with
# the monitor's own Paperclip key, which can run only the monitor's
# routines. It runs as its own user, not the monitor's, so it can't read
# the agent's logins or sessions, and it reaches only Paperclip on loopback
# and the lab's sources. lab-health-dry-run prints the codes and starts
# nothing.
{ config, lib, pkgs, ... }:
let
  cfg = config.agents.labHealth;
  hermes = config.roles.hermesAgents;
  observe = hermes.observe;
  monitor = hermes.instances.monitor or null;
  intake = config.agents.watch.intake;
  ready = monitor != null && monitor.secrets ? PAPERCLIP_AGENT_KEY && lib.any (s: s != null) (lib.attrValues observe);
  hostOf = url: lib.head (lib.splitString ":" (lib.head (lib.splitString "/" (lib.last (lib.splitString "://" url)))));
  stateDir = "/var/lib/lab-health";
  # Each source's addresses: Proxmox's nodes and Kuma and Alerta by address,
  # Beszel by name, at the address the agents' egress allows for it.
  addresses = lib.unique ([ "localhost" ]
    ++ lib.optionals (observe.proxmox != null) (map hostOf observe.proxmox.urls)
    ++ lib.optional (observe.beszel != null) config.roles.agentEgress.allow.beszel.address
    ++ lib.optional (observe.kuma != null) (hostOf observe.kuma.url)
    ++ lib.optional (observe.alerta != null) (hostOf observe.alerta.url));
  secretOf = name: config.sops.secrets.${name}.path;
  credentials = [ "paperclip-key:${secretOf monitor.secrets.PAPERCLIP_AGENT_KEY}" ]
    ++ lib.optional (observe.proxmox != null) "proxmox-token:${secretOf observe.proxmox.secret}"
    ++ lib.optional (observe.beszel != null) "beszel-password:${secretOf observe.beszel.secret}"
    ++ lib.optional (observe.alerta != null) "alerta-key:${secretOf observe.alerta.secret}";
  join = lib.concatStringsSep ",";

  service = description: args: {
    inherit description;
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "podman-paperclip.service" ];
    environment = {
      LAB_SERVER = "${../../modules/roles/hermes-agents/lab-mcp/server.py}";
      PAPERCLIP_URL = "http://127.0.0.1:${toString config.roles.paperclip.port}";
      ROUTINE_TITLE = cfg.routineTitle;
      STATE_DIR = stateDir;
      STORAGE_PERCENT = toString cfg.storagePercent;
      DISK_PERCENT = toString cfg.diskPercent;
      MEMORY_PERCENT = toString cfg.memoryPercent;
      TASK_HOURS = toString cfg.taskHours;
      ALERT_HOURS = toString cfg.alertHours;
      EXPECTED_OFFLINE = join cfg.expectedOffline;
      # The alert intake's own rules, so an alert only counts as stale when
      # the triage would have taken it.
      INTAKE_SEVERITIES = join intake.severities;
      INTAKE_IGNORE_ORIGINS = join intake.ignoreOrigins;
      INTAKE_HARMLESS = join intake.harmless;
      # For Beszel's HTTPS; Python doesn't find the bundle itself.
      SSL_CERT_FILE = config.security.pki.caBundle;
    } // lib.optionalAttrs (observe.proxmox != null) {
      PROXMOX_URLS = join observe.proxmox.urls;
      PROXMOX_CA = "${observe.proxmox.caFile}";
    } // lib.optionalAttrs (observe.beszel != null) {
      BESZEL_URL = observe.beszel.url;
      BESZEL_USER = observe.beszel.user;
    } // lib.optionalAttrs (observe.kuma != null) {
      KUMA_URL = observe.kuma.url;
      KUMA_SLUG = observe.kuma.slug;
    } // lib.optionalAttrs (observe.alerta != null) {
      ALERTA_URL = observe.alerta.url;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe pkgs.python3} -I ${./lab-health/lab-health.py}${args}";
      TimeoutStartSec = "5min";
      User = "lab-health";
      Group = "lab-health";
      LoadCredential = credentials;
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
      IPAddressAllow = addresses;
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
in
{
  options.agents.labHealth = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether the morning check runs, waking the monitor only when it finds something.";
    };

    storagePercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 85;
      description = "Proxmox storage this full or more is a finding.";
    };

    diskPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 85;
      description = "A Beszel system's disk this full or more is a finding.";
    };

    memoryPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 90;
      description = "A Beszel system's memory this full or more is a finding.";
    };

    taskHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "A Proxmox task that failed this recently is a finding.";
    };

    alertHours = lib.mkOption {
      type = lib.types.ints.positive;
      default = 24;
      description = "An alert the triage would take, open this long, is a finding.";
    };

    expectedOffline = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-z0-9][a-z0-9-]*");
      default = [ ];
      description = "Proxmox nodes that are meant to be off, so their being offline isn't a finding.";
    };

    routineTitle = lib.mkOption {
      type = lib.types.str;
      default = "Look into {{count}} lab finding(s)";
      description = "The monitor's routine for findings, by its title in scripts/agents/paperclip-spec.json.";
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
      description = "Whether the check runs: enabled, with the monitor's Paperclip key and a lab source set up.";
    };
  };

  config = lib.mkMerge [
    {
      warnings = lib.optional (cfg.enable && !ready)
        "agents: lab-health is off until the monitor has its Paperclip key and the lab tools have a source.";
    }
    (lib.mkIf cfg.active {
      assertions = [ {
        # Proxmox, Kuma and Alerta by address only, since its unit allows addresses, and only those.
        assertion = lib.all (address: address == "localhost" || builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+" address != null) addresses
          && lib.all (unit: config.systemd.services.${unit}.serviceConfig.IPAddressAllow == addresses
            && config.systemd.services.${unit}.serviceConfig.IPAddressDeny == [ "any" ]) [ "lab-health" "lab-health-dry-run" ];
        message = "agents: lab-health reaches only Paperclip on loopback and the lab's sources, by address: IPAddressAllow is ${builtins.toJSON addresses} and IPAddressDeny is any.";
      } ];

      users.users.lab-health = {
        isSystemUser = true;
        group = "lab-health";
      };
      users.groups.lab-health = { };

      systemd.tmpfiles.rules = [ "d ${stateDir} 0755 lab-health lab-health - -" ];

      systemd.services.lab-health = service "The lab's morning check, for the monitor" "";
      systemd.services.lab-health-dry-run = service "The lab's morning check, printed, starting nothing" " --dry-run";

      systemd.timers.lab-health = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 07:00:00 America/New_York";
          Persistent = true;
        };
      };
    })
  ];
}
