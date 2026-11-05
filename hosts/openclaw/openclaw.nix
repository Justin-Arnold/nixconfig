# The concierge (roles.openclaw): OpenClaw as the one agent Justin talks to.
# It turns what he asks for into Paperclip issues for the coordinator, checks
# on them and reports back. Paperclip is its only tool, through the same MCP
# server the Hermes agents use; it has no shell, files, browser, web access
# or way to change its own setup.
{ config, lib, pkgs, ... }:
let
  inherit (config.openclaw.concierge) withPaperclipKey discordUserId telegramUserId;

  paperclipMcp = pkgs.callPackage ../../modules/roles/hermes-agents/paperclip-mcp/package.nix { };
  # Enough to file, follow and discuss work, to read what's waiting on
  # approval, and to finish the runs Paperclip wakes it for: Paperclip wants
  # each to end with the issue's status set, and only lets an agent change
  # issues assigned to it. No documents or approvals of its own.
  paperclipTools = [
    "paperclipMe" "paperclipInboxLite" "paperclipGetHeartbeatContext"
    "paperclipListAgents" "paperclipGetAgent"
    "paperclipListIssues" "paperclipGetIssue" "paperclipCreateIssue"
    "paperclipCheckoutIssue" "paperclipUpdateIssue" "paperclipReleaseIssue"
    "paperclipListComments" "paperclipGetComment" "paperclipAddComment"
    "paperclipListProjects" "paperclipGetProject" "paperclipListGoals" "paperclipGetGoal"
    "paperclipListApprovals" "paperclipGetApproval" "paperclipListIssueApprovals"
  ];

  dm = id: tokenSetting: tokenVar: {
    enabled = true;
    ${tokenSetting} = "\${${tokenVar}}";
    dmPolicy = "allowlist";
    allowFrom = [ id ];
    groupPolicy = "disabled";
  };
  secret = name: config.sops.placeholder."openclaw/${name}";
in
{
  options.openclaw.concierge = {
    withPaperclipKey = lib.mkOption {
      type = lib.types.bool;
      description = "Whether openclaw/paperclip-key is in SOPS, which gives the concierge its Paperclip tools.";
    };
    discordUserId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "Justin's Discord user id. With it, the Discord bot takes his DMs and nothing else.";
    };
    telegramUserId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      description = "Justin's Telegram user id. With it, the Telegram bot takes his DMs and nothing else.";
    };
  };

  config = {
    # The concierge's Paperclip agent key is openclaw/paperclip-key; without
    # it, it has no tools at all. A channel stays off until Justin's id is
    # here and its bot token is in SOPS.
    openclaw.concierge = {
      withPaperclipKey = true;
      discordUserId = null;
      telegramUserId = null;
    };

    roles.openclaw = {
      enable = true;
      environmentFiles = [ config.sops.templates."openclaw.env".path ];
      workspaceFiles = {
        "AGENTS.md" = ./workspace/AGENTS.md;
        "SOUL.md" = ./workspace/SOUL.md;
        "IDENTITY.md" = ./workspace/IDENTITY.md;
      };

      settings = {
        gateway = {
          mode = "local";
          bind = "loopback";
          port = config.roles.openclaw.port;
          auth = {
            mode = "token";
            token = "\${OPENCLAW_GATEWAY_TOKEN}";
            allowTailscale = false;
          };
          # nginx on this host; it overwrites X-Forwarded-For with the client.
          trustedProxies = [ "127.0.0.1" ];
          publicOrigin = "https://openclaw.servicestack.xyz";
          controlUi = {
            enabled = true;
            automaticallyFetchFavicons = false;
          };
          # It would open a shell on this host from the Control UI.
          terminal.enabled = false;
          cliAgents.enabled = false;
        };

        agents.defaults = {
          workspace = "${config.roles.openclaw.stateDir}/workspace";
          # The workspace files come from this repo (workspaceFiles above).
          skipBootstrap = true;
          model = {
            primary = "openai/gpt-6.1-sol";
            fallbacks = [ "openai/gpt-6-sol" ];
          };
          sandbox.mode = "off";
          skills = [ ];
        };

        # Codex's own runtime would bring its shell and file tools along.
        models.providers.openai.agentRuntime.id = "openclaw";

        tools = {
          profile = "minimal";
          alsoAllow = lib.optional withPaperclipKey "bundle-mcp";
          deny = [
            "gateway" "openclaw" "plugins" "cron" "skill_workshop" "browser"
            "sessions_spawn" "sessions_send"
            "group:runtime" "group:fs" "group:web" "group:ui" "group:automation" "group:nodes" "group:media"
          ];
          exec.mode = "deny";
          elevated.enabled = false;
          web = {
            search.enabled = false;
            fetch.enabled = false;
          };
          fs.workspaceOnly = true;
          sessions.visibility = "agent";
          agentToAgent.enabled = false;
          message.crossContext = {
            allowWithinProvider = false;
            allowAcrossProviders = false;
          };
        };

        browser.enabled = false;
        plugins.entries.browser.enabled = false;
        skills = {
          allowBundled = [ ];
          workshop.autonomous.mode = "off";
        };
        # No skill or plugin installs from anywhere.
        security.installPolicy.enabled = true;
        commands = {
          bash = false;
          config = false;
          mcp = false;
          plugins = false;
        };
        hooks.enabled = false;
        # /tmp is private to the unit and gone on restart.
        logging.file = "${config.roles.openclaw.stateDir}/logs/openclaw.log";
        session.dmScope = "per-channel-peer";

        mcp.servers = lib.optionalAttrs withPaperclipKey {
          paperclip = {
            command = lib.getExe paperclipMcp;
            env = {
              PAPERCLIP_API_URL = "https://paperclip.servicestack.xyz";
              PAPERCLIP_API_KEY = "\${PAPERCLIP_AGENT_KEY}";
            };
            toolFilter.include = paperclipTools;
          };
        };

        channels = {
          discord = if discordUserId == null then { enabled = false; }
            else dm discordUserId "token" "DISCORD_BOT_TOKEN";
          telegram = if telegramUserId == null then { enabled = false; }
            else dm telegramUserId "botToken" "TELEGRAM_BOT_TOKEN";
        };
      };
    };

    sops.secrets = {
      "openclaw/gateway-token" = { };
    } // lib.optionalAttrs withPaperclipKey {
      "openclaw/paperclip-key" = { };
    } // lib.optionalAttrs (discordUserId != null) {
      "openclaw/discord-token" = { };
    } // lib.optionalAttrs (telegramUserId != null) {
      "openclaw/telegram-token" = { };
    };

    # Root-only: systemd reads it into the gateway's environment, and
    # openclaw-admin reads it under sudo.
    sops.templates."openclaw.env" = {
      content = ''
        OPENCLAW_GATEWAY_TOKEN=${secret "gateway-token"}
      '' + lib.optionalString withPaperclipKey ''
        PAPERCLIP_AGENT_KEY=${secret "paperclip-key"}
      '' + lib.optionalString (discordUserId != null) ''
        DISCORD_BOT_TOKEN=${secret "discord-token"}
      '' + lib.optionalString (telegramUserId != null) ''
        TELEGRAM_BOT_TOKEN=${secret "telegram-token"}
      '';
      restartUnits = [ "openclaw-gateway.service" ];
    };

    warnings =
      lib.optional (!withPaperclipKey)
        "openclaw: the concierge has no Paperclip key yet (withPaperclipKey in hosts/openclaw/openclaw.nix), so it has no tools."
      ++ lib.optional (discordUserId == null && telegramUserId == null)
        "openclaw: no chat channels yet; the Control UI is the only way in.";
  };
}
