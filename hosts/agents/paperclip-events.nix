# paperclip-events: Paperclip's live events, as a nudge to each service on
# this host that acts on them, so they react in seconds instead of waiting
# for their timers. See paperclip-events/paperclip-events.py.
#
# The relay holds Paperclip's websocket with its own key on the researcher
# (the websocket takes agent keys only) and, for each event a consumer
# wants, leaves a file in /run/paperclip-events/<consumer>.d/. A path unit
# starts the consumer while that folder isn't empty; the consumer empties it
# as it starts and waits cooldownSeconds after it stops. So events during a
# pass cause one more pass, and a burst causes one. The consumers keep
# their timers as a slower sweep. Events only say that something changed;
# each consumer reads what it needs from Paperclip itself.
#
# The relay reaches Paperclip on loopback and nothing else, and runs as its
# own user with its key as a systemd credential.
{ config, lib, pkgs, ... }:
let
  cfg = config.agents.events;
  eventsDir = "/run/paperclip-events";
  stateDir = "/var/lib/paperclip-events";
  python = import ./paperclip-events/python.nix { inherit pkgs; };
  hermes = config.roles.hermesAgents;

  # The agents agent-costs runs for, as ./agent-costs.nix picks them.
  costAgents = lib.optionals config.agents.costs.enable
    (lib.attrNames (lib.filterAttrs (_: a: a.secrets ? PAPERCLIP_AGENT_KEY) hermes.instances));
  # The oneshot services nudged straight. board-bridge runs all the time,
  # so it's nudged through a kick that sends it SIGHUP.
  oneshots = lib.optional config.agents.watch.enable "agent-watch"
    ++ lib.optional config.agents.monitorIntake.active "monitor-intake"
    ++ map (name: "agent-costs-${name}") costAgents;
  bridge = config.agents.boardBridge.enable;
  consumers = oneshots ++ lib.optional bridge "board-bridge";

  folder = consumer: "${eventsDir}/${consumer}.d";
  clear = consumer: "${pkgs.coreutils}/bin/rm -f ${folder consumer}/pending";
in
{
  options.agents.events = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether Paperclip's live events nudge agent-watch, board-bridge, monitor-intake and agent-costs. Its key on the researcher has to be in SOPS first.";
    };

    cooldownSeconds = lib.mkOption {
      type = lib.types.ints.between 0 120;
      default = 10;
      description = "How long a nudged service waits after a pass before events can start another, so a busy run's many changes become a few passes.";
    };

    statusFile = lib.mkOption {
      type = lib.types.str;
      default = "${stateDir}/status.json";
      readOnly = true;
      description = "Whether the relay is connected, when it last was, and what last went wrong, for agent-watch.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The consumers' timers become a slower sweep. agent-watch keeps its five
    # minutes for what's about time passing, and monitor-intake its two
    # until alerts reach it as events too.
    agents.boardBridge.pollSeconds = lib.mkDefault 300;
    agents.costs.every = lib.mkDefault "hourly";

    assertions = [
      {
        # It needs Paperclip and nothing else.
        assertion = config.systemd.services.paperclip-events.serviceConfig.IPAddressAllow == [ "localhost" ]
          && config.systemd.services.paperclip-events.serviceConfig.IPAddressDeny == [ "any" ];
        message = "agents: paperclip-events reaches only Paperclip on loopback: IPAddressAllow is localhost and IPAddressDeny is any.";
      }
    ];

    sops.secrets."paperclip-events/paperclip-key" = { };

    users.users.paperclip-events = {
      isSystemUser = true;
      group = "paperclip-events";
    };
    users.groups.paperclip-events = { };

    # The folders outlive the relay's restarts, so a path unit never loses
    # what it watches.
    systemd.tmpfiles.rules = [ "d ${eventsDir} 0755 paperclip-events paperclip-events - -" ]
      ++ map (c: "d ${folder c} 0755 paperclip-events paperclip-events - -") consumers;

    systemd.services = {
      paperclip-events = {
        description = "Paperclip's live events, as nudges to the services that act on them";
        wantedBy = [ "multi-user.target" ];
        after = [ "podman-paperclip.service" "systemd-tmpfiles-setup.service" ];
        environment = {
          PAPERCLIP_URL = "http://127.0.0.1:${toString config.roles.paperclip.port}";
          EVENTS_DIR = eventsDir;
          STATE_DIR = stateDir;
          CONSUMERS = lib.concatStringsSep " " (lib.subtractLists (map (n: "agent-costs-${n}") costAgents) consumers);
          COST_AGENTS = lib.concatStringsSep " " costAgents;
        };
        serviceConfig = {
          ExecStart = "${python}/bin/python3 -I ${./paperclip-events/paperclip-events.py}";
          Restart = "always";
          RestartSec = "5s";
          User = "paperclip-events";
          Group = "paperclip-events";
          StateDirectory = "paperclip-events";
          # agent-watch reads status.json.
          StateDirectoryMode = "0755";
          ReadWritePaths = [ eventsDir ];
          LoadCredential = [ "paperclip-key:${config.sops.secrets."paperclip-events/paperclip-key".path}" ];
          UMask = "0022";
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
      };
    }
    # Each nudged oneshot empties its folder as root as it starts (its own
    # user can't), and waits after it stops, whether it worked or not.
    // lib.genAttrs oneshots (consumer: {
      serviceConfig = {
        ExecStartPre = [ "+${clear consumer}" ];
        ExecStopPost = [ "${pkgs.coreutils}/bin/sleep ${toString cfg.cooldownSeconds}" ];
      };
    })
    // lib.optionalAttrs bridge {
      board-bridge-kick = {
        description = "Tell board-bridge to read Paperclip now";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = [
            (clear "board-bridge")
            # If the bridge isn't running there's no one to tell; its start
            # reads Paperclip anyway.
            "-${config.systemd.package}/bin/systemctl kill --signal=SIGHUP --kill-whom=main board-bridge.service"
          ];
          ExecStopPost = [ "${pkgs.coreutils}/bin/sleep 2" ];
        };
      };
    };

    systemd.paths = lib.listToAttrs (map (consumer: lib.nameValuePair "paperclip-events-${consumer}" {
      wantedBy = [ "paths.target" ];
      pathConfig = {
        DirectoryNotEmpty = folder consumer;
        Unit = if consumer == "board-bridge" then "board-bridge-kick.service" else "${consumer}.service";
      };
    }) consumers);
  };
}
