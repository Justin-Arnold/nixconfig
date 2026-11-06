# board-bridge: what waits on the board in Paperclip (questions,
# confirmations and approvals) goes to Justin as Telegram and Discord DMs,
# and a tap answers it in Paperclip as him, which wakes the agent that
# asked. See board-bridge/board-bridge.py.
#
# It holds a board key, which can do anything the board can, so its code
# calls only the few routes it needs and refuses the rest. Only presses from
# the user IDs below, in a DM, count. It polls Telegram and holds Discord's
# gateway open, so nothing reaches it from outside, and it reaches Paperclip
# on loopback and the internet, never the LAN. It runs as its own user with
# its secrets as systemd credentials.
{ config, lib, pkgs, ... }:
let
  cfg = config.agents.boardBridge;
  spec = builtins.fromJSON (builtins.readFile ../../scripts/agents/paperclip-spec.json);
  stateDir = "/var/lib/board-bridge";
  python = import ./board-bridge/python.nix { inherit pkgs; };
  # Telegram and Discord are on the internet; the LAN and the lab aren't
  # anything it needs.
  privateRanges = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "169.254.0.0/16" "fc00::/7" "fe80::/10" ];
  on = channel: cfg.${channel}.enable && cfg.${channel}.userId != null;
  channel = name: {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether ${name} gets the board's questions, once its user ID is set.";
    };
    userId = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[0-9]+");
      default = null;
      description = "Justin's ${name} user ID. Only his presses and replies count, and only in a DM.";
    };
  };
in
{
  options.agents.boardBridge = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether the board's questions and approvals go to Telegram and Discord. The board key and each channel's bot token have to be in SOPS first.";
    };

    pollSeconds = lib.mkOption {
      type = lib.types.ints.between 5 300;
      default = 20;
      description = "How often it reads Paperclip.";
    };

    telegram = channel "Telegram";
    discord = channel "Discord";

    statusFile = lib.mkOption {
      type = lib.types.str;
      default = "${stateDir}/status.json";
      readOnly = true;
      description = "When a pass last worked, what last went wrong, and which channel answered what, for agent-watch.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = on "telegram" || on "discord";
        message = "agents: board-bridge needs Telegram or Discord on, with Justin's user ID (agents.boardBridge.<channel>.userId).";
      }
      {
        # The board key mustn't reach anything on the LAN, only Paperclip
        # here and the chat services out there.
        assertion = config.systemd.services.board-bridge.serviceConfig.IPAddressAllow == [ "localhost" ]
          && lib.all (range: lib.elem range config.systemd.services.board-bridge.serviceConfig.IPAddressDeny) privateRanges;
        message = "agents: board-bridge reaches only loopback and the internet: IPAddressAllow is localhost alone and IPAddressDeny holds every private range.";
      }
    ];

    sops.secrets = {
      "paperclip/board-bridge-key" = { };
    } // lib.optionalAttrs (on "telegram") {
      "board-bridge/telegram-token" = { };
    } // lib.optionalAttrs (on "discord") {
      "board-bridge/discord-token" = { };
    };

    users.users.board-bridge = {
      isSystemUser = true;
      group = "board-bridge";
    };
    users.groups.board-bridge = { };

    systemd.services.board-bridge = {
      description = "Paperclip's questions and approvals for the board, on Telegram and Discord";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "podman-paperclip.service" ];
      environment = {
        PAPERCLIP_URL = "http://127.0.0.1:${toString config.roles.paperclip.port}";
        PAPERCLIP_LINK = "${config.roles.paperclip.publicUrl}/${spec.company.issuePrefix}";
        COMPANY_PREFIX = spec.company.issuePrefix;
        STATE_DIR = stateDir;
        POLL_SECONDS = toString cfg.pollSeconds;
        # For HTTPS to Telegram and Discord; Python doesn't find the bundle itself.
        SSL_CERT_FILE = config.security.pki.caBundle;
      } // lib.optionalAttrs (on "telegram") {
        TELEGRAM_USER = cfg.telegram.userId;
      } // lib.optionalAttrs (on "discord") {
        DISCORD_USER = cfg.discord.userId;
      };
      serviceConfig = {
        ExecStart = "${python}/bin/python3 -I ${./board-bridge/board-bridge.py}";
        Restart = "always";
        RestartSec = "15s";
        User = "board-bridge";
        Group = "board-bridge";
        StateDirectory = "board-bridge";
        # agent-watch reads status.json; state.json is the bridge's alone.
        StateDirectoryMode = "0755";
        LoadCredential = [ "paperclip-key:${config.sops.secrets."paperclip/board-bridge-key".path}" ]
          ++ lib.optional (on "telegram") "telegram-token:${config.sops.secrets."board-bridge/telegram-token".path}"
          ++ lib.optional (on "discord") "discord-token:${config.sops.secrets."board-bridge/discord-token".path}";
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
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = privateRanges;
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
  };
}
