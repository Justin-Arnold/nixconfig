# OpenClaw's gateway (roles.openclaw): the chat front door to the agents, as
# one locked-down unit on loopback, behind nginx.
#
# nix-openclaw's own NixOS module writes the config world-readable under /etc
# and hardens nothing, so this role runs the gateway from nix-openclaw's
# package itself. `settings` becomes openclaw.json. Its type is OpenClaw's
# own config schema, which nix-openclaw generates as Nix options for the
# release it packages, so an unknown key or a value the gateway would refuse
# fails evaluation instead of the gateway's start. The file is copied
# into the state directory, readable by the gateway's user only, on every
# start, and OPENCLAW_NIX_MODE keeps the gateway from changing it. Secrets
# never go in it: they're ${VAR} references, filled from the environment
# files when the gateway loads it.
#
# `sudo openclaw-admin <args>` runs the OpenClaw CLI as the gateway's user
# with the same config and secrets: device pairing, the ChatGPT login,
# `security audit`.
{ config, lib, pkgs, inputs, ... }:
let
  cfg = config.roles.openclaw;
  json = pkgs.formats.json { };
  schema = import "${inputs.nix-openclaw}/nix/generated/openclaw-config-options.nix" { inherit lib; };

  # Every option the schema doesn't set is null; the file only has the rest.
  stripNulls = value:
    if lib.isAttrs value then lib.filterAttrs (_: v: v != null) (lib.mapAttrs (_: stripNulls) value)
    else if lib.isList value then lib.filter (v: v != null) (map stripNulls value)
    else value;
  rendered = stripNulls cfg.settings;
  configFile = json.generate "openclaw.json" rendered;
  openclaw = lib.getExe' cfg.package "openclaw";

  environment = {
    HOME = cfg.stateDir;
    OPENCLAW_STATE_DIR = cfg.stateDir;
    OPENCLAW_CONFIG_PATH = "${cfg.stateDir}/openclaw.json";
    # The config is read-only to the gateway: no config writes, no plugin or
    # skill installs, no self-update.
    OPENCLAW_NIX_MODE = "1";
    # No mDNS announcements on the LAN.
    OPENCLAW_DISABLE_BONJOUR = "1";
  };

  # Copies the config and the workspace files in, replacing whatever is there.
  install = pkgs.writeShellScript "openclaw-install-config" ''
    set -eu
    rm -f ${cfg.stateDir}/openclaw.json
    install -m 0400 ${configFile} ${cfg.stateDir}/openclaw.json
    install -d -m 0700 ${cfg.stateDir}/workspace
    ${lib.concatStrings (lib.mapAttrsToList (name: file: ''
      rm -f ${cfg.stateDir}/workspace/${name}
      install -m 0400 ${file} ${cfg.stateDir}/workspace/${name}
    '') cfg.workspaceFiles)}
  '';

  admin = pkgs.writeShellApplication {
    name = "openclaw-admin";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      if [[ $EUID -ne 0 ]]; then
        echo "openclaw-admin: run it with sudo" >&2
        exit 1
      fi
      set -a
      ${lib.concatMapStrings (f: "# shellcheck source=/dev/null\n. ${f}\n") cfg.environmentFiles}
      set +a
      ${lib.concatStrings (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}\n") environment)}
      cd ${cfg.stateDir}
      exec runuser -u ${cfg.user} -- ${openclaw} "$@"
    '';
  };
in
{
  options.roles.openclaw = {
    enable = lib.mkEnableOption "the OpenClaw gateway";

    package = lib.mkOption {
      type = lib.types.package;
      default = inputs.nix-openclaw.packages.${pkgs.stdenv.hostPlatform.system}.openclaw-gateway;
      defaultText = lib.literalExpression "inputs.nix-openclaw.packages.<system>.openclaw-gateway";
      description = "The gateway, without the extra tools nix-openclaw's default package puts on its PATH.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "openclaw";
      description = "The gateway's user.";
    };

    uid = lib.mkOption {
      type = lib.types.int;
      default = 3401;
      description = "Fixed, so the egress filter can match it.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/openclaw";
      description = "Sessions, logins, pairings, the workspace and the copied config.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 18789;
      description = "Loopback port for the Control UI and the WebSocket.";
    };

    settings = lib.mkOption {
      type = lib.types.submodule { options = schema; };
      default = { };
      description = "openclaw.json, checked against OpenClaw's schema. Secrets only as \${VAR} references.";
    };

    renderedSettings = lib.mkOption {
      type = json.type;
      readOnly = true;
      default = rendered;
      description = "settings as they go into openclaw.json, without the unset options.";
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = "Files of VAR=value lines the \${VAR} references in settings come from.";
    };

    workspaceFiles = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression ''{ "SOUL.md" = ./soul.md; }'';
      description = "Files copied into the agent's workspace on every start, read-only.";
    };

    memory = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = "MemoryMax for the gateway.";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      default = configFile;
      description = "The rendered openclaw.json, for checks.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasInfix "\"dangerously" (builtins.toJSON rendered));
        message = "roles.openclaw: no dangerously* settings.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) uid;
      group = cfg.user;
      home = cfg.stateDir;
    };
    users.groups.${cfg.user}.gid = cfg.uid;

    environment.systemPackages = [ admin ];

    systemd.services.openclaw-gateway = {
      description = "OpenClaw gateway";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      inherit environment;
      restartTriggers = [ configFile ] ++ lib.attrValues cfg.workspaceFiles;

      serviceConfig = {
        User = cfg.user;
        Group = cfg.user;
        StateDirectory = lib.removePrefix "/var/lib/" cfg.stateDir;
        StateDirectoryMode = "0700";
        WorkingDirectory = cfg.stateDir;
        EnvironmentFile = cfg.environmentFiles;
        ExecStartPre = install;
        ExecStart = "${openclaw} gateway --bind loopback --port ${toString cfg.port}";
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "30s";
        UMask = "0077";
        MemoryMax = cfg.memory;
        TasksMax = 256;

        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.stateDir ];
        InaccessiblePaths = [ "-/var/lib/sops-nix" ];
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        # Netlink for Node's os.networkInterfaces(), which the gateway calls.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
      };
    };
  };
}
