# agent-costs: after each of an agent's runs (./paperclip-events.nix starts
# it) and on a timer anyway, that agent's Claude and Jev spend goes to
# Paperclip as cost events, and into /var/lib/agent-costs/<name>/month.json
# for agent-watch's credit alerts. See agent-costs/agent-costs.py.
#
# Paperclip records every hermes_gateway run as unpriced, and Hermes knows
# what each call cost, so this carries one to the other. Each agent's job
# runs as that agent, reads only its own state.db and logs, and posts with
# its own Paperclip key, which can only report that agent's own costs.
# Only Claude and Jev cost money; Codex is part of the ChatGPT plan and the
# lab's model is free.
{ config, lib, pkgs, ... }:
let
  cfg = config.agents.costs;
  hermes = config.roles.hermesAgents;
  # Every agent with a Paperclip key: the job posts with it.
  agents = lib.attrNames (lib.filterAttrs (_: a: a.secrets ? PAPERCLIP_AGENT_KEY) hermes.instances);
  outOf = name: "/var/lib/agent-costs/${name}";
in
{
  options.agents.costs = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether each agent's spend goes to Paperclip and agent-watch.";
    };

    every = lib.mkOption {
      type = lib.types.str;
      default = "*:0/15";
      example = "hourly";
      description = "When each agent's job runs on its timer (systemd OnCalendar). With paperclip-events on it also runs after each of that agent's runs, so this is only a sweep.";
    };

    claudeMonthlyCredits = lib.mkOption {
      type = lib.types.ints.positive;
      default = 100;
      description = "Dollars of Claude credit loaded each month; agent-watch warns as the agents' spend nears it.";
    };

    claudeWarnPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 80;
      description = "How much of the month's Claude credit the agents may spend before agent-watch warns.";
    };

    jevCentsPerMillion = lib.mkOption {
      type = lib.types.number;
      default = 4.2;
      description = "What Jev charges per million input tokens, in cents. Output is free.";
    };
  };

  config = lib.mkIf (cfg.enable && agents != [ ]) {
    systemd.tmpfiles.rules = [ "d /var/lib/agent-costs 0755 root root - -" ]
      ++ map (name: "d ${outOf name} 0755 hermes-${name} hermes-${name} - -") agents;

    systemd.services = lib.listToAttrs (map (name: lib.nameValuePair "agent-costs-${name}" {
      description = "Report ${name}'s Claude and Jev spend to Paperclip";
      after = [ "podman-paperclip.service" ];
      environment = {
        AGENT = name;
        HERMES_HOME = "/var/lib/hermes-${name}/.hermes";
        OUT_DIR = outOf name;
        PAPERCLIP_URL = "http://127.0.0.1:${toString config.roles.paperclip.port}";
        PRICES = builtins.toJSON hermes.anthropic.prices;
        JEV_CENTS_PER_MILLION = toString cfg.jevCentsPerMillion;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe pkgs.python3} -I ${./agent-costs/agent-costs.py}";
        TimeoutStartSec = "3min";
        User = "hermes-${name}";
        Group = "hermes-${name}";
        LoadCredential = [ "paperclip-key:${config.sops.secrets."hermes/${name}/paperclip-key".path}" ];
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ (outOf name) ];
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
        # Paperclip on loopback is all it talks to.
        IPAddressAllow = [ "localhost" ];
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
    }) agents);

    systemd.timers = lib.listToAttrs (map (name: lib.nameValuePair "agent-costs-${name}" {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.every;
        RandomizedDelaySec = "60s";
      };
    }) agents);
  };
}
