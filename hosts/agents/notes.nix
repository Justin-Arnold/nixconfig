# The vault: Justin's second brain, one Obsidian vault on Obsidian Sync, for
# the agents. Three parts, all as the `notes` user:
#
#   notes-sync  Obsidian's headless client (`ob sync --continuous`) keeps this
#               host's copy at /var/lib/notes/vault: the notes and Sync's
#               default attachments (images, audio, PDFs and video), but no
#               .obsidian settings, where plugins keep their keys. The
#               agents' tools open Markdown only, and notes-scan doesn't read
#               attachments. It reaches loopback and the internet, never the
#               LAN.
#   notes       the vault service (notes/notes.py), on a socket only the
#               agents' users can open, with no network at all. It knows the
#               caller from the socket, commits each agent's change under its
#               name in a git repo kept only here, and refuses secrets. The
#               agents' notes MCP server is its only client.
#   notes-scan  every 15 minutes, gitleaks and the service's own checks over
#               the new commits, Justin's included, waking the monitor with
#               what they find, the way lab-health does.
#   notes-mirror  within seconds of each commit, `git push --mirror` of the
#               history to forge (git.lab118.xyz), where Justin reads it. A
#               path unit on the vault's branches starts it, and an hourly
#               timer catches a missed start. It reaches forge's SSH port and
#               nothing else, can't write to the vault, and holds a deploy key
#               for that one repository, which the other units can't read.
#               agent-watch raises MirrorStale from its status file when it
#               hasn't pushed for two and a half hours.
#
# Setting up Sync is a one-time step after the first switch, with Justin's
# Obsidian login (account-wide; it stays in /var/lib/notes/config):
#
#   sudo notes-ob login
#   sudo notes-ob sync-list-remote
#   sudo notes-ob sync-setup --vault "<vault>" --path /var/lib/notes/vault --device-name agents
#   sudo notes-ob sync-config --path /var/lib/notes/vault --file-types "" --configs "" --conflict-strategy merge
#   sudo systemctl start notes-sync
#
# In ob 0.0.14 an empty `--file-types` means Sync's default attachment types,
# not none; the command line can't turn them all off. An empty `--configs`
# does turn the settings off.
#
# Until then notes-sync is skipped and the vault is empty. Run
# `sudo systemctl start notes-scan-dry-run` and read its journal once the
# first sync is done, before relying on what the agents can read.
{ config, lib, pkgs, ... }:
let
  cfg = config.agents.notes;
  hermes = config.roles.hermesAgents;
  monitor = hermes.instances.monitor or null;
  stateDir = "/var/lib/notes";
  vault = "${stateDir}/vault";
  clients = lib.attrNames (lib.filterAttrs (_: i: i.notes.enable) hermes.instances);
  ob = pkgs.obsidian-headless;
  python = lib.getExe pkgs.python3;
  patterns = "${../../modules/roles/hermes-agents/jev-mcp/server.py}";
  secretOf = name: config.sops.secrets.${name}.path;
  privateRanges = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "169.254.0.0/16" "fc00::/7" "fe80::/10" ];
  ready = monitor != null && monitor.secrets ? PAPERCLIP_AGENT_KEY;
  svc = config.systemd.services;

  # notes-mirror runs as notes, in a group of its own that no user is in. The
  # group can read the deploy key and the firewall lets it reach forge's SSH
  # port, so the other units, which run as notes too, get neither.
  forge = import ../forge/facts.nix;
  mirror = cfg.mirror;
  mirrorGroup = "notes-mirror";
  mirrorGid = 3390;
  deployKey = "notes/forge-deploy-key";
  forgeKnownHosts = pkgs.writeText "forge-known-hosts" "${mirror.address} ${toString mirror.hostKey}\n";
  mirrorSsh = lib.concatStringsSep " " [
    "${pkgs.openssh}/bin/ssh" "-F none" "-i ${secretOf deployKey}"
    "-o IdentitiesOnly=yes" "-o IdentityAgent=none" "-o BatchMode=yes"
    "-o StrictHostKeyChecking=yes" "-o UserKnownHostsFile=${forgeKnownHosts}" "-o GlobalKnownHostsFile=/dev/null"
    "-o ConnectTimeout=15" "-o ServerAliveInterval=15" "-o ServerAliveCountMax=4"
  ];

  hardening = {
    User = "notes";
    Group = "notes";
    UMask = "0077";
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
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
    CapabilityBoundingSet = "";
  };

  scanService = description: args: {
    inherit description;
    after = [ "notes.service" "podman-paperclip.service" ];
    path = [ pkgs.git pkgs.gitleaks ];
    environment = {
      VAULT = vault;
      STATE_DIR = stateDir;
      NOTES_SERVICE = "${./notes/notes.py}";
      NOTES_PATTERNS = patterns;
      PAPERCLIP_URL = "http://127.0.0.1:${toString config.roles.paperclip.port}";
      ROUTINE_TITLE = cfg.scan.routineTitle;
      SCAN_ALLOW = lib.concatStringsSep "," cfg.scan.allow;
    };
    serviceConfig = hardening // {
      Type = "oneshot";
      ExecStart = "${python} -I ${./notes/notes-scan.py}${args}";
      TimeoutStartSec = "15min";
      LoadCredential = [ "paperclip-key:${secretOf monitor.secrets.PAPERCLIP_AGENT_KEY}" ];
      ProcSubset = "pid";
      IPAddressAllow = [ "localhost" ];
      IPAddressDeny = [ "any" ];
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  # `sudo notes-ob <args>`: Obsidian's headless client as the vault's user,
  # with its login and settings in /var/lib/notes/config.
  notesOb = pkgs.writeShellApplication {
    name = "notes-ob";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      if [[ $EUID -ne 0 ]]; then
        echo "notes-ob: run it with sudo" >&2
        exit 1
      fi
      cd ${vault}
      exec runuser -u notes -- env HOME=${stateDir} XDG_CONFIG_HOME=${stateDir}/config ${ob}/bin/ob "$@"
    '';
  };
in
{
  options.agents.notes = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the vault runs: Sync, the vault service and the scan. Sync is set up by hand after the first switch.";
    };

    toAgents = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether every agent gets the notes tools. Off for the first sync, until
        `notes-scan-dry-run` over the whole vault is clean.
      '';
    };

    socket = lib.mkOption {
      type = lib.types.str;
      default = "/run/notes/notes.sock";
      readOnly = true;
      description = "The vault service's socket, which the agents' notes MCP server opens.";
    };

    vault = lib.mkOption {
      type = lib.types.str;
      default = vault;
      readOnly = true;
      description = "This host's copy of the vault, and its git history.";
    };

    writesPerHour = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Changes one agent may make to the vault in an hour.";
    };

    maxNoteBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 262144;
      description = "The biggest note an agent may write.";
    };

    scan = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether new commits are checked for secrets and private data, waking the monitor with findings.";
      };
      every = lib.mkOption {
        type = lib.types.str;
        default = "*:0/15";
        description = "When the scan runs (systemd OnCalendar).";
      };
      routineTitle = lib.mkOption {
        type = lib.types.str;
        default = "Look into {{count}} vault finding(s)";
        description = "The monitor's routine for findings, by its title in scripts/agents/paperclip-spec.json.";
      };
      allow = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9 ._:/@-]+");
        default = [ ];
        description = "Finding codes Justin has cleared, as notes-scan prints them.";
      };
      active = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable && cfg.scan.enable && ready;
        readOnly = true;
        description = "Whether the scan runs: the vault on, the scan on, and the monitor with its Paperclip key.";
      };
    };

    mirror = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the vault's history is pushed to forge after every commit. It waits for forge's SSH host key.";
      };
      address = lib.mkOption {
        type = lib.types.strMatching "[0-9]{1,3}(\\.[0-9]{1,3}){3}";
        default = forge.address;
        description = "forge's address. The mirror reaches it by address, so it needs no DNS.";
      };
      hostKey = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "ssh-ed25519 [A-Za-z0-9+/=]+( .*)?");
        default = forge.sshHostKey;
        description = "forge's ed25519 SSH host key, pinned. null keeps the mirror off.";
      };
      repo = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+";
        default = "justin/vault";
        description = "The repository on forge, as owner/name. Its deploy key is the only key that can write to it.";
      };
      every = lib.mkOption {
        type = lib.types.str;
        default = "hourly";
        description = "When the mirror runs besides after each commit (systemd OnCalendar), in case a start was missed.";
      };
      statusFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/notes-mirror/status.json";
        readOnly = true;
        description = "Where notes-mirror writes when it last pushed and why it last failed, for agent-watch's MirrorStale.";
      };
      active = lib.mkOption {
        type = lib.types.bool;
        default = cfg.enable && mirror.enable && mirror.hostKey != null;
        readOnly = true;
        description = "Whether the mirror runs: the vault on, the mirror on, and forge's host key known.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      warnings = lib.optional (cfg.scan.enable && !ready)
        "agents: notes-scan is off until the monitor has its Paperclip key."
        ++ lib.optional (mirror.enable && mirror.hostKey == null)
        "agents: notes-mirror is off until forge's SSH host key is in hosts/forge/facts.nix (02. Areas/Homelab/Hosts/forge.md in Justin's vault, \"First install\").";

      assertions = [
        {
          assertion = svc.notes.serviceConfig.PrivateNetwork && svc.notes.serviceConfig.IPAddressDeny == [ "any" ]
            && svc.notes.serviceConfig.RestrictAddressFamilies == [ "AF_UNIX" ];
          message = "agents: the vault service has no network; the agents reach it only on its socket.";
        }
        {
          assertion = config.systemd.sockets.notes.socketConfig.SocketMode == "0660"
            && config.systemd.sockets.notes.socketConfig.SocketGroup == "notes-clients";
          message = "agents: the vault's socket is for the notes-clients group (the agents) only, mode 0660.";
        }
        {
          # The Obsidian login reaches every vault on the account; the LAN is
          # nothing it needs.
          assertion = svc.notes-sync.serviceConfig.IPAddressAllow == [ "localhost" ]
            && lib.all (range: lib.elem range svc.notes-sync.serviceConfig.IPAddressDeny) privateRanges;
          message = "agents: notes-sync reaches only loopback and the internet: IPAddressAllow is localhost alone and IPAddressDeny holds every private range.";
        }
        {
          assertion = lib.all (n: lib.elem "-${stateDir}" svc."hermes-${n}".serviceConfig.InaccessiblePaths) (lib.attrNames hermes.instances);
          message = "agents: no agent can open the vault's files or Obsidian login (${stateDir}); they go through the vault service.";
        }
        {
          assertion = lib.all (n: !(lib.hasPrefix "notes/" n)) (lib.concatMap (i: lib.attrValues i.secrets) (lib.attrValues hermes.instances));
          message = "agents: no agent is given a notes/* secret.";
        }
      ];

      users.users = {
        notes = {
          isSystemUser = true;
          group = "notes";
          home = stateDir;
        };
      } // lib.genAttrs (map (n: "hermes-${n}") clients) (_: { extraGroups = [ "notes-clients" ]; });
      users.groups.notes = { };
      users.groups.notes-clients = { };

      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 notes notes - -"
        "d ${vault} 0700 notes notes - -"
        "d ${stateDir}/config 0700 notes notes - -"
      ];

      systemd.sockets.notes = {
        description = "The vault service's socket, for the agents";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ cfg.socket ];
        socketConfig = {
          SocketUser = "notes";
          SocketGroup = "notes-clients";
          SocketMode = "0660";
          DirectoryMode = "0755";
        };
      };

      systemd.services.notes = {
        description = "The vault service for the agents";
        wantedBy = [ "multi-user.target" ];
        requires = [ "notes.socket" ];
        after = [ "notes.socket" ];
        path = [ pkgs.git ];
        environment = {
          VAULT = vault;
          STATE_DIR = stateDir;
          NOTES_AGENTS = lib.concatStringsSep "," (map (n: "${toString hermes.instances.${n}.uid}=${n}") clients);
          NOTES_PATTERNS = patterns;
          WRITES_PER_HOUR = toString cfg.writesPerHour;
          MAX_NOTE_BYTES = toString cfg.maxNoteBytes;
        };
        serviceConfig = hardening // {
          ExecStart = "${python} -I ${./notes/notes.py}";
          Restart = "always";
          RestartSec = "5s";
          MemoryMax = "1G";
          ProcSubset = "pid";
          PrivateNetwork = true;
          IPAddressDeny = [ "any" ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
        };
      };

      systemd.services.notes-sync = {
        description = "Obsidian Sync for the vault (the headless client)";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        # Skipped until `notes-ob sync-setup` has set the vault up.
        unitConfig.ConditionPathExistsGlob = "${stateDir}/config/obsidian-headless/sync/*/config.json";
        environment = {
          HOME = stateDir;
          XDG_CONFIG_HOME = "${stateDir}/config";
        };
        serviceConfig = hardening // {
          ExecStart = "${ob}/bin/ob sync --continuous --path ${vault}";
          Restart = "always";
          RestartSec = "30s";
          MemoryMax = "1G";
          # Node compiles JavaScript into executable memory.
          MemoryDenyWriteExecute = false;
          IPAddressAllow = [ "localhost" ];
          IPAddressDeny = privateRanges;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK" ];
        };
      };

      environment.systemPackages = [ notesOb ];

      # The git history exists only here; Sync and Justin's devices have the notes.
      roles.sqliteBackup.files.notes-vault = vault;
    }

    (lib.mkIf cfg.scan.active {
      assertions = [ {
        assertion = lib.all (unit: svc.${unit}.serviceConfig.IPAddressAllow == [ "localhost" ]
          && svc.${unit}.serviceConfig.IPAddressDeny == [ "any" ]) [ "notes-scan" "notes-scan-dry-run" ];
        message = "agents: notes-scan reaches only Paperclip on loopback.";
      } ];

      systemd.services.notes-scan = scanService "Checks the vault's new commits for secrets, for the monitor" "";
      systemd.services.notes-scan-dry-run = scanService "Checks the vault's whole history for secrets, printed, starting nothing" " --dry-run";

      systemd.timers.notes-scan = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.scan.every;
          Persistent = true;
        };
      };
    })

    (lib.mkIf mirror.active {
      assertions = [
        {
          assertion = svc.notes-mirror.serviceConfig.IPAddressAllow == [ mirror.address ]
            && svc.notes-mirror.serviceConfig.IPAddressDeny == [ "any" ];
          message = "agents: notes-mirror reaches forge (${mirror.address}) and nothing else.";
        }
        {
          # The cgroup filter can't tell ports apart; this rule does.
          assertion = config.networking.nftables.enable
            && lib.hasInfix "meta skgid ${toString mirrorGid} ip daddr ${mirror.address} tcp dport ${toString forge.sshPort} accept"
              config.networking.nftables.tables.notes-mirror.content;
          message = "agents: the notes-mirror group reaches forge's SSH port (${toString forge.sshPort}) and no other port.";
        }
        {
          assertion = svc.notes-mirror.serviceConfig.Group == mirrorGroup && svc.notes-mirror.serviceConfig.ReadWritePaths == [ ];
          message = "agents: notes-mirror runs in the notes-mirror group and can't write to the vault.";
        }
        {
          assertion = let key = config.sops.secrets.${deployKey}; in key.owner == "root" && key.group == mirrorGroup && key.mode == "0440";
          message = "agents: only root and the notes-mirror group can read forge's deploy key, so the other notes units can't.";
        }
        {
          assertion = lib.all (u: !(lib.elem mirrorGroup u.extraGroups) && u.group != mirrorGroup) (lib.attrValues config.users.users);
          message = "agents: no user is in the notes-mirror group; only notes-mirror's unit runs with it.";
        }
      ];

      users.groups.${mirrorGroup}.gid = mirrorGid;

      sops.secrets.${deployKey} = {
        owner = "root";
        group = mirrorGroup;
        mode = "0440";
      };

      # By the socket's group: the notes-mirror group may open a connection to
      # forge's SSH port, and nothing else.
      networking.nftables.enable = true;
      networking.nftables.tables.notes-mirror = {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy accept;
            meta skgid ${toString mirrorGid} ip daddr ${mirror.address} tcp dport ${toString forge.sshPort} accept comment "forge's SSH"
            meta skgid ${toString mirrorGid} counter reject with icmpx admin-prohibited comment "anything else from notes-mirror"
          }
        '';
      };

      systemd.services.notes-mirror = {
        description = "Pushes the vault's history to forge";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        unitConfig.ConditionPathIsDirectory = "${vault}/.git";
        path = [ pkgs.git pkgs.jq ];
        environment = {
          VAULT = vault;
          MIRROR_URL = "ssh://${forge.sshUser}@${mirror.address}:${toString forge.sshPort}/${mirror.repo}.git";
          GIT_SSH_COMMAND = mirrorSsh;
          STATUS = mirror.statusFile;
        };
        serviceConfig = hardening // {
          Type = "oneshot";
          Group = mirrorGroup;
          ExecStart = "${pkgs.bash}/bin/bash ${./notes/notes-mirror.sh}";
          ReadWritePaths = [ ];
          # agent-watch reads status.json there. It holds times and git's
          # first error line, nothing from the vault.
          StateDirectory = "notes-mirror";
          StateDirectoryMode = "0755";
          TimeoutStartSec = "5min";
          # While forge is down: again after 30 s, backing off to every 30 min.
          Restart = "on-failure";
          RestartSec = "30s";
          RestartSteps = 6;
          RestartMaxDelaySec = "30min";
          ProcSubset = "pid";
          IPAddressAllow = [ mirror.address ];
          IPAddressDeny = [ "any" ];
          RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
        };
      };

      # A commit writes refs/heads/<branch>.lock and renames it into place.
      systemd.paths.notes-mirror = {
        description = "Starts notes-mirror when a branch moves in the vault";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathChanged = "${vault}/.git/refs/heads";
          Unit = "notes-mirror.service";
        };
      };

      systemd.timers.notes-mirror = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = mirror.every;
          Persistent = true;
        };
      };
    })
  ]);
}
