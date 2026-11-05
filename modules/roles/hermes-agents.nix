# Hermes agents on this host, one process each (roles.hermesAgents).
#
# Paperclip's hermes_gateway adapter wakes an agent through its API server on
# 127.0.0.1, and the agent works on Paperclip through Paperclip's MCP server,
# which Hermes starts as a child over stdio with that agent's own Paperclip
# key. Neither direction needs a shell on this host.
#
# Upstream's NixOS module (services.hermes-agent) runs a single instance, and
# each agent here needs its own memory, sessions, model login and keys. So
# this role runs one unit per instance and builds each one with upstream's
# own helpers (nix/moduleCommon.nix in the pinned flake input): config.yaml,
# .env, SOUL.md and the command line come out as upstream renders them.
#
# Every instance:
#   - runs as its own system user, with a fixed uid so restored files keep
#     their owner, and HERMES_HOME in /var/lib/hermes-<name>/.hermes
#   - is managed (HERMES_MANAGED), and its config.yaml, .env and SOUL.md
#     belong to root, so the agent can read them but not rewrite them
#   - has no messaging platforms, cron, kanban, browser or skill installs
#   - has dangerous-command approvals on; nobody is attached to an API run,
#     so a request is denied, and the deny globs hold even under --yolo
#   - gets only the toolsets it's given. The ones that act on a machine
#     (terminal, file, code execution) need an ssh terminal backend, so they
#     act on that machine and never on this one.
#   - can use the endpoints in `providers`, over HTTPS, with each key in
#     .env from SOPS and only its variable's name in config.yaml
{ config, lib, pkgs, inputs, ... }:
let
  osConfig = config;
  cfg = config.roles.hermesAgents;
  common = import "${inputs.hermes-agent}/nix/moduleCommon.nix" { inherit lib; };
  hermesPackage = inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default;
  paperclipMcp = pkgs.callPackage ./hermes-agents/paperclip-mcp/package.nix { };
  jevMcp = pkgs.callPackage ./hermes-agents/jev-mcp/package.nix { };

  # The MCP servers an agent may run: this role's own packages, each taking
  # only its own key from .env.
  mcpAllowed = {
    paperclip = { command = lib.getExe paperclipMcp; key = "PAPERCLIP_AGENT_KEY"; };
    jev = { command = lib.getExe jevMcp; key = "JEV_API_KEY"; };
  };
  # The variables a string asks Hermes to fill in: ${VAR} or ${env:VAR}.
  refsIn = s: map (m: lib.removePrefix "env:" (lib.trim (lib.head m)))
    (lib.filter lib.isList (builtins.split "\\$\\{([^}]*)}" s));

  # Ways Hermes would use Claude other than the API key from SOPS: an OAuth
  # token it ranks above the key, which Anthropic's terms don't allow for a
  # third-party harness, or another endpoint to send the key to.
  anthropicForbidden = [ "ANTHROPIC_TOKEN" "ANTHROPIC_AUTH_TOKEN" "CLAUDE_CODE_OAUTH_TOKEN" "ANTHROPIC_BASE_URL" ];

  # Before each start, as the agent's user: Nix can't see a login someone
  # added by hand (`hermes-agent <name> auth add anthropic`), and Hermes
  # would use it before the API key. Hermes keeps the API key itself in the
  # pool as an `env:ANTHROPIC_API_KEY` reference, which is fine; anything
  # else for Anthropic isn't. An OAuth token where the API key should be is
  # refused too.
  claudeCheck = name: pkgs.writeShellScript "hermes-${name}-claude-check" ''
    home=${stateDirOf name}/.hermes
    if [ -f "$home/auth.json" ] && ${lib.getExe pkgs.jq} -e \
        '((.providers.anthropic // null) != null)
         or ([(.credential_pool.anthropic // [])[]? | select((.source // "") != "env:ANTHROPIC_API_KEY")] | length > 0)' \
        "$home/auth.json" >/dev/null 2>&1; then
      echo "hermes-${name}: $home/auth.json has an Anthropic login, which Hermes would use before the API key from SOPS; remove its anthropic entries" >&2
      exit 1
    fi
    if [ -f "$home/.env" ] && ${lib.getExe pkgs.gnugrep} -q '^ANTHROPIC_API_KEY=sk-ant-oat' "$home/.env"; then
      echo "hermes-${name}: the Anthropic key in SOPS is an OAuth token; it has to be an API key from the Console" >&2
      exit 1
    fi
  '';

  # Toolsets that run commands or touch files where the terminal backend is.
  machineToolsets = [ "terminal" "file" "code_execution" "coding" "debugging" "project" ];

  # Never offered: they act on this host (browser, computer_use), schedule or
  # dispatch work outside Paperclip (cronjob, kanban), connect outside
  # services (connections) or post to chat platforms.
  neverToolsets = [
    "browser" "computer_use" "desktop_ui" "cronjob" "kanban" "connections" "bot_room"
    "discord" "discord_admin" "yuanbao" "feishu_doc" "feishu_drive"
  ];

  # Paperclip MCP tools an agent may use. Left out: the raw API escape hatch,
  # approval decisions (the board's job), workspace service control, revision
  # restores and outside connections. Paperclip's own key checks apply too.
  paperclipTools = [
    "paperclipMe" "paperclipInboxLite" "paperclipGetHeartbeatContext"
    "paperclipListIssues" "paperclipGetIssue" "paperclipCreateIssue" "paperclipUpdateIssue"
    "paperclipCheckoutIssue" "paperclipReleaseIssue"
    "paperclipListComments" "paperclipGetComment" "paperclipAddComment"
    "paperclipListDocuments" "paperclipGetDocument" "paperclipListDocumentRevisions" "paperclipUpsertIssueDocument"
    "paperclipListProjects" "paperclipGetProject" "paperclipListGoals" "paperclipGetGoal" "paperclipListAgents" "paperclipGetAgent"
    "paperclipListIssueApprovals" "paperclipListApprovals" "paperclipGetApproval" "paperclipGetApprovalIssues"
    "paperclipListApprovalComments" "paperclipCreateApproval" "paperclipLinkIssueApproval" "paperclipAddApprovalComment"
    "paperclipAskUserQuestions" "paperclipRequestConfirmation" "paperclipRequestCheckboxConfirmation"
  ];

  # Blocked even under --yolo or approvals.mode off (fnmatch on the command).
  denyCommands = [
    "sudo *" "su *" "doas *"
    "git push --force*" "git push -f*" "git push * --force*" "git push * -f*" "git push * +*"
    "git push * --delete *" "git push * :*" "git branch -D *" "git reset --hard *" "git clean -*"
    "rm -rf /*" "rm -rf ~*" "rm -fr /*" "mkfs*" "dd *of=/dev/*" "shutdown*" "reboot*" "systemctl *"
    "nix run *#switch*" "nixos-rebuild *" "terraform apply*" "terraform destroy*" "tofu apply*" "tofu destroy*"
    "gh pr merge*" "gh repo delete*" "gh release delete*"
    # DELETE calls, with -X or --method anywhere after `gh api`, spaced or not.
    "gh api *-X DELETE*" "gh api *-XDELETE*" "gh api *--method DELETE*" "gh api *--method=DELETE*"
    "curl * | *sh*" "wget * | *sh*"
  ];

  stateDirOf = name: "/var/lib/hermes-${name}";
  userOf = name: "hermes-${name}";

  # Names Hermes already means something by: `local` and `custom` are
  # aliases of its generic custom endpoint, the llama.cpp spellings start a
  # managed server, and the rest are built-in providers with their own setup.
  reservedProviderNames = [
    "local" "custom" "auto" "llamacpp" "llama.cpp" "llama-cpp" "ollama" "lmstudio" "vllm"
    "openai" "openai-codex" "anthropic" "openrouter" "nous" "gemini"
  ];

  # Side tasks that always get an explicit value in config.yaml. Hermes
  # merges these settings into the config.yaml it keeps on disk and keeps
  # keys that are no longer set, so a task taken out of Nix would otherwise
  # stay where it was; `auto` hands it back to the agent's main model.
  managedSideTasks = [ "title_generation" "background_review" "compression" ];

  modelType = lib.types.submodule {
    options = {
      provider = lib.mkOption {
        type = lib.types.str;
        example = "openai-codex";
        description = "Hermes inference provider.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        example = "gpt-6.1-sol";
        description = "Model name as the provider knows it.";
      };
    };
  };

  instanceModule = { name, config, ... }: {
    options = common.sharedOptions {
      defaultPackage = cfg.package;
      defaultPackageText = lib.literalExpression "roles.hermesAgents.package";
      defaultWorkingDirectory = "${stateDirOf name}/workspace";
      defaultWorkingDirectoryText = lib.literalExpression ''"/var/lib/hermes-<name>/workspace"'';
    } // {
      uid = lib.mkOption {
        type = lib.types.int;
        description = "uid and gid of the instance's user. Fixed so restored files keep their owner.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = "API server port on 127.0.0.1. Paperclip's hermes_gateway adapter calls it.";
      };

      model = lib.mkOption {
        type = modelType;
        description = "The model the agent runs on (model.provider and model.default).";
      };

      fallbacks = lib.mkOption {
        type = lib.types.listOf modelType;
        default = [ ];
        description = ''
          Models to switch to, in order, when the current one fails a run
          (fallback_providers). Another model on the same provider counts.
        '';
      };

      auxiliary = lib.mkOption {
        type = lib.types.attrsOf modelType;
        default = { };
        example = lib.literalExpression ''{ compression = { provider = "openai-codex"; name = "gpt-6.1-terra"; }; }'';
        description = ''
          Models for this agent's side tasks (auxiliary.<task>), on top of
          roles.hermesAgents.sideTasks. A task set in neither runs on the
          agent's main model.
        '';
      };

      jev.enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.jev.enable;
        defaultText = lib.literalExpression "roles.hermesAgents.jev.enable";
        description = "Give this agent the Jev decision tool.";
      };

      soul = lib.mkOption {
        type = lib.types.lines;
        description = "SOUL.md: who the agent is and how it works.";
      };

      toolsets = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "memory" "todo" "session_search" ];
        description = ''
          Toolsets the API server offers (platform_toolsets.api_server), besides
          the Paperclip MCP tools. Toolsets that act on a machine need
          terminal.ssh.
        '';
      };

      terminal.ssh = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            host = lib.mkOption { type = lib.types.str; };
            user = lib.mkOption { type = lib.types.str; };
            port = lib.mkOption { type = lib.types.port; default = 22; };
            keySecret = lib.mkOption {
              type = lib.types.str;
              description = "SOPS secret with the private key, installed for the instance's user.";
            };
            knownHosts = lib.mkOption {
              type = lib.types.lines;
              description = "known_hosts lines for the host, so the first connection can't be intercepted.";
            };
            cwd = lib.mkOption { type = lib.types.str; description = "Working directory on the host."; };
          };
        });
        default = null;
        description = "Run the terminal, file and code tools on this host over ssh.";
      };

      extraDenyCommands = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "git push*" ];
        description = ''
          Commands this agent may never run, on top of the deny list every
          agent has (fnmatch on the command, like approvals.deny).
        '';
      };

      secrets = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = { PAPERCLIP_AGENT_KEY = "hermes/coordinator/paperclip-key"; };
        description = ''
          Environment variables from SOPS (variable -> secret name), added to
          .env by a root-only template. API_SERVER_KEY is always there.
          PAPERCLIP_AGENT_KEY, when set, turns on the Paperclip MCP server.
        '';
      };

      memory = lib.mkOption {
        type = lib.types.str;
        default = "2G";
        description = "MemoryMax for the unit, including the MCP servers it starts.";
      };
    };

    config = let
      # From the typed options only: secrets feed settings, so reading
      # settings here would loop.
      usesClaude = lib.any (m: m.provider == "anthropic")
        ([ config.model ] ++ config.fallbacks ++ lib.attrValues (cfg.sideTasks // config.auxiliary));
    in {
      # Every agent gets every endpoint's key, by reference: .env has the
      # variable, config.yaml only its name. The Anthropic key goes only to
      # agents that use Claude, and Jev's to agents with the tool.
      secrets = { API_SERVER_KEY = lib.mkDefault "hermes/${name}/api-server-key"; }
        // lib.mapAttrs' (_: p: lib.nameValuePair p.keyEnv (lib.mkDefault p.keySecret)) cfg.providers
        // lib.optionalAttrs (usesClaude && cfg.anthropic.keySecret != null) {
          ANTHROPIC_API_KEY = lib.mkDefault cfg.anthropic.keySecret;
        }
        // lib.optionalAttrs config.jev.enable { JEV_API_KEY = lib.mkDefault cfg.jev.keySecret; };
      hermesHomeFiles."SOUL.md" = config.soul;
      environment = {
        API_SERVER_ENABLED = "true";
        API_SERVER_HOST = "127.0.0.1";
        API_SERVER_PORT = toString config.port;
      };
      environmentFiles = [ osConfig.sops.templates."hermes-${name}.env".path ];
      # Sampling stays off on both: with it, a server could ask the agent's
      # own models for completions.
      mcpServers = lib.mkMerge [
        (lib.mkIf (config.secrets ? PAPERCLIP_AGENT_KEY) {
          paperclip = {
            command = lib.getExe paperclipMcp;
            env = {
              PAPERCLIP_API_URL = "http://127.0.0.1:${toString cfg.paperclipPort}";
              # Hermes fills this from .env when it starts the server.
              PAPERCLIP_API_KEY = "\${PAPERCLIP_AGENT_KEY}";
            };
            tools.include = paperclipTools;
            sampling.enabled = false;
          };
        })
        (lib.mkIf config.jev.enable {
          jev = {
            command = lib.getExe jevMcp;
            env = {
              JEV_API_KEY = "\${JEV_API_KEY}";
              JEV_BASE_URL = cfg.jev.baseUrl;
              JEV_MODEL = cfg.jev.model;
              # Call ids, times and outcomes only; the smoke test reads it.
              JEV_CALL_LOG = "${stateDirOf name}/.hermes/logs/jev.log";
            };
            tools.include = [ "decide" ];
            timeout = 60;
            sampling.enabled = false;
          };
        })
      ];
      # settings is a raw attribute set (it becomes config.yaml as written), so
      # conditional parts use optionalAttrs, not mkIf.
      settings = lib.optionalAttrs (config.mcpServers != { }) {
        # Neither server's resources or prompts become tools, and Jev's calls
        # are counted: past the limit in one session, Hermes wants an
        # approval nobody can give.
        mcp_servers = lib.recursiveUpdate (common.mcpServersToConfig config.mcpServers)
          (lib.mapAttrs (n: _: { tools = { resources = false; prompts = false; }; }
            // lib.optionalAttrs (n == "jev") {
              tool_costs.decide = 1;
              cost_unit = "calls";
              spend_limit = cfg.jev.callsPerSession;
            }) config.mcpServers);
      } // lib.optionalAttrs (config.fallbacks != [ ]) {
        # A Claude entry names its key, so Hermes takes the API key rather
        # than looking for a login first.
        fallback_providers = map (m: { inherit (m) provider; model = m.name; }
          // lib.optionalAttrs (m.provider == "anthropic") { key_env = "ANTHROPIC_API_KEY"; }) config.fallbacks;
      } // lib.optionalAttrs (cfg.providers != { }) {
        providers = lib.mapAttrs (_: p: {
          base_url = p.baseUrl;
          key_env = p.keyEnv;
          request_timeout_seconds = p.requestTimeout;
          stale_timeout_seconds = p.staleTimeout;
          # Without it Hermes asks the server, and llama-server reports the
          # model's trained context, not a slot's.
          models = lib.mapAttrs (_: m: { context_length = m.contextLength; }) p.models;
        }) cfg.providers;
      } // {
        auxiliary = lib.genAttrs managedSideTasks (_: { provider = "auto"; model = ""; })
          // lib.mapAttrs (_: m: { inherit (m) provider; model = m.name; }) (cfg.sideTasks // config.auxiliary);
        model = { inherit (config.model) provider; default = config.model.name; };
        # Naming an MCP server here makes this an allowlist, so every server
        # the agent should see has to be named.
        platform_toolsets.api_server = config.toolsets
          ++ lib.optional (config.secrets ? PAPERCLIP_AGENT_KEY) "paperclip"
          ++ lib.optional config.jev.enable "jev";
        agent.disabled_toolsets = neverToolsets
          ++ lib.optionals (config.terminal.ssh == null) machineToolsets;
        terminal = if config.terminal.ssh == null then { backend = "local"; } else {
          backend = "ssh";
          inherit (config.terminal.ssh) cwd;
          ssh_host = config.terminal.ssh.host;
          ssh_user = config.terminal.ssh.user;
          ssh_port = config.terminal.ssh.port;
          ssh_key = "${stateDirOf name}/.ssh/id_ed25519";
        };
        approvals = {
          mode = "manual";
          # Paperclip starts runs with /v1/runs, which tells Hermes a client
          # can answer an approval, but its adapter never does. A flagged
          # command would wait out the default 300 s before being denied,
          # and the agent reads the silence as waiting on Justin.
          timeout = 5;
          unattended_mode = "deny";
          cron_mode = "deny";
          single_query_mode = "deny";
          deny = denyCommands ++ config.extraDenyCommands;
        };
        cron.allow_agent_scheduling = false;
        kanban = { dispatch_in_gateway = false; notify_in_gateway = false; auto_subscribe_on_create = false; };
        skills = { project_discovery = false; write_approval = true; inline_shell = false; };
        security = { allow_private_urls = false; redact_secrets = true; allow_lazy_installs = false; };
        auth.adopt_external_logins = false;
        updates.check = false;
        telemetry.shared_metrics = { enabled = false; send = false; };
      };
    };
  };

  instances = cfg.instances;
  names = lib.attrNames instances;
in
{
  options.roles.hermesAgents = {
    enable = lib.mkEnableOption "Hermes agents, one process per instance";

    package = lib.mkOption {
      type = lib.types.package;
      default = hermesPackage;
      defaultText = lib.literalExpression "inputs.hermes-agent.packages.\${system}.default";
      description = "The Hermes package every instance runs unless it sets its own.";
    };

    paperclipPort = lib.mkOption {
      type = lib.types.port;
      default = config.roles.paperclip.port or 3100;
      defaultText = lib.literalExpression "config.roles.paperclip.port";
      description = "Paperclip's port on 127.0.0.1, for the MCP server.";
    };

    providers = lib.mkOption {
      description = ''
        OpenAI-compatible endpoints every agent can use, by name: the name
        goes in a model's `provider`. Each one's key reaches every agent's
        .env from SOPS, and config.yaml names only the variable.
      '';
      default = { };
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          baseUrl = lib.mkOption {
            type = lib.types.str;
            example = "https://inference.servicestack.xyz/v1";
            description = "The endpoint, HTTPS only.";
          };
          keyEnv = lib.mkOption {
            type = lib.types.strMatching "[A-Z][A-Z0-9_]*";
            example = "LAB_INFERENCE_KEY";
            description = "Environment variable the key is in.";
          };
          keySecret = lib.mkOption {
            type = lib.types.str;
            example = "inference/agents-key";
            description = "SOPS secret with the key.";
          };
          models = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options.contextLength = lib.mkOption {
                type = lib.types.ints.positive;
                description = "Tokens of context a request gets. Hermes refuses less than 64,000.";
              };
            });
            description = "The models it serves, by the name a request asks for.";
          };
          requestTimeout = lib.mkOption {
            type = lib.types.ints.positive;
            default = 600;
            description = "Seconds a request may take in all.";
          };
          staleTimeout = lib.mkOption {
            type = lib.types.ints.positive;
            default = 180;
            description = "Seconds a streamed answer may go without a chunk.";
          };
        };
      });
    };

    sideTasks = lib.mkOption {
      type = lib.types.attrsOf modelType;
      default = { };
      example = lib.literalExpression ''{ title_generation = { provider = "lab-gpu"; name = "local"; }; }'';
      description = ''
        Models for side tasks (auxiliary.<task>) on every agent. An agent's
        own `auxiliary` wins over these. Hermes falls back to the agent's
        main model when one fails.
      '';
    };

    anthropic = {
      keySecret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "anthropic/api-key";
        description = ''
          SOPS secret with an Anthropic API key. The Console's spend limits
          (the workspace's, else the organization's) are the only cap on it,
          since Paperclip doesn't price these runs. It reaches only the agents whose
          model, fallbacks or side tasks use the `anthropic` provider, as
          ANTHROPIC_API_KEY.
        '';
      };
      models = lib.mkOption {
        type = lib.types.nonEmptyListOf lib.types.str;
        default = [ "claude-opus-5-5" "claude-sonnet-5-5" "claude-haiku-5-5" ];
        description = "The Claude models an agent may use; anything else is refused.";
      };
    };

    jev = {
      enable = lib.mkEnableOption "the Jev decision tool for every agent (each can opt out with jev.enable)";
      baseUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://api.typesafe.ai/v1";
        description = "A System One endpoint (POST <baseUrl>/systemone), HTTPS only.";
      };
      model = lib.mkOption {
        type = lib.types.str;
        default = "jev-1.14.0";
        description = "A pinned Jev version, so answers stay comparable over time.";
      };
      keySecret = lib.mkOption {
        type = lib.types.str;
        default = "jev/api-key";
        description = "SOPS secret with the TypeSafe API key, given to every agent with the tool as JEV_API_KEY.";
      };
      callsPerSession = lib.mkOption {
        type = lib.types.ints.positive;
        default = 25;
        description = "Jev calls one session may make before Hermes wants an approval, which an unattended run can't get.";
      };
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule instanceModule);
      default = { };
      description = "The agents. The attribute name is the agent's short name.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = lib.length (lib.unique (map (n: instances.${n}.port) names)) == lib.length names;
          message = "roles.hermesAgents: two instances use the same port.";
        }
        {
          assertion = lib.length (lib.unique (map (n: instances.${n}.uid) names)) == lib.length names;
          message = "roles.hermesAgents: two instances use the same uid.";
        }
      ]
      ++ lib.concatLists (lib.mapAttrsToList (pname: p: [
        {
          assertion = !(lib.elem pname reservedProviderNames);
          message = "roles.hermesAgents.providers.${pname}: Hermes already means something by that name; pick another.";
        }
        {
          assertion = lib.hasPrefix "https://" p.baseUrl;
          message = "roles.hermesAgents.providers.${pname}: the endpoint must be HTTPS (got ${p.baseUrl}).";
        }
        {
          assertion = p.models != { } && lib.all (m: m.contextLength >= 64000) (lib.attrValues p.models);
          message = "roles.hermesAgents.providers.${pname}: list its models, each with at least 64,000 tokens of context; Hermes refuses less.";
        }
      ]) cfg.providers)
      ++ [
        {
          assertion = lib.hasPrefix "https://" cfg.jev.baseUrl;
          message = "roles.hermesAgents.jev.baseUrl: HTTPS only (got ${cfg.jev.baseUrl}).";
        }
      ]
      ++ lib.concatMap (name:
        let
          inst = instances.${name};
          s = inst.settings;
          env = inst.environment;
          opt = "roles.hermesAgents.instances.${name}";
          machineTools = lib.intersectLists machineToolsets inst.toolsets;
          ours = lib.attrNames cfg.providers;
          tasks = cfg.sideTasks // inst.auxiliary;
          unlisted = lib.filter (m: lib.elem m.provider ours && !(cfg.providers.${m.provider}.models ? ${m.name}))
            ([ inst.model ] ++ inst.fallbacks ++ lib.attrValues tasks);
          # Every block that can carry a key or an endpoint of its own.
          blocks = lib.filter lib.isAttrs (lib.attrValues (s.providers or { }) ++ lib.attrValues (s.auxiliary or { })
            ++ (s.fallback_providers or [ ]) ++ [ (s.model or { }) ]);
          endpointOf = e: e.base_url or e.url or e.api or "";
          claudeTyped = lib.filter (m: m.provider == "anthropic") ([ inst.model ] ++ inst.fallbacks ++ lib.attrValues tasks);
          # As rendered, so Claude added straight through settings counts too.
          claudeRendered = lib.filter (e: (e.provider or "") == "anthropic") (lib.filter lib.isAttrs
            ([ (s.model or { }) ] ++ (s.fallback_providers or [ ]) ++ lib.attrValues (s.auxiliary or { })));
          claudeModels = map (m: m.name) claudeTyped ++ map (e: e.model or e.default or "") claudeRendered;
          servers = s.mcp_servers or { };
          serverOk = n: srv: mcpAllowed ? ${n}
            && (srv.command or null) == mcpAllowed.${n}.command
            && !(srv ? url) && !(srv ? headers) && !(srv ? auth)
            && ((srv.sampling or { }).enabled or true) == false
            && lib.all (ref: ref == mcpAllowed.${n}.key) (refsIn (builtins.toJSON srv))
            && lib.all (var: builtins.match ".*(KEY|TOKEN|SECRET|PASSWORD).*" (lib.toUpper var) == null
              || lib.hasPrefix "\${" srv.env.${var}) (lib.attrNames (srv.env or { }));
        in
        [
          {
            assertion = lib.all (e: (e.api_key or "") == "" && !(e ? key_cmd) && !(e ? api_key_cmd)) blocks;
            message = "${opt}: keys go in by reference only (key_env), never as api_key or key_cmd in providers, side tasks, fallbacks or the model.";
          }
          {
            assertion = lib.all (e: (e.base_url or "") == "")
              (lib.filter lib.isAttrs (lib.attrValues (s.auxiliary or { }) ++ (s.fallback_providers or [ ]) ++ [ (s.model or { }) ]));
            message = "${opt}: the model, fallbacks and side tasks reach an endpoint only through a provider (no base_url of their own).";
          }
          {
            assertion = lib.all (e: lib.hasPrefix "https://" (endpointOf e)) (lib.attrValues (s.providers or { }));
            message = "${opt}: every provider endpoint is HTTPS.";
          }
          {
            assertion = lib.all (p: (inst.secrets.${p.keyEnv} or null) == p.keySecret) (lib.attrValues cfg.providers);
            message = "${opt}: each provider's key variable must come from its SOPS secret.";
          }
          {
            assertion = unlisted == [ ];
            message = "${opt}: these ask a provider for a model it doesn't list: ${toString (map (m: "${m.provider}/${m.name}") unlisted)}.";
          }
          {
            # Not local yet: a weak summary loses an agent's context for good.
            assertion = !(lib.elem (tasks.compression or inst.model).provider ours);
            message = "${opt}: context compression stays on a cloud model; set auxiliary.compression when the main model is local.";
          }
          {
            assertion = env.API_SERVER_HOST == "127.0.0.1" && !(lib.elem inst.port config.networking.firewall.allowedTCPPorts);
            message = "${opt}: the API server must stay on 127.0.0.1, with its port closed.";
          }
          {
            assertion = inst.terminal.ssh != null || machineTools == [ ];
            message = "${opt}: ${toString machineTools} would act on this host; they need terminal.ssh.";
          }
          {
            assertion = (s.terminal.backend or "local") == (if inst.terminal.ssh == null then "local" else "ssh");
            message = "${opt}: settings.terminal.backend must come from terminal.ssh.";
          }
          {
            # Hermes copies these to the terminal's host, where generated code runs.
            assertion = !(s.terminal ? credential_files) && !(s.terminal ? env_passthrough);
            message = "${opt}: terminal.credential_files and terminal.env_passthrough would copy files and secrets to the terminal's host.";
          }
          {
            assertion = lib.intersectLists neverToolsets inst.toolsets == [ ]
              && lib.all (t: lib.elem t (s.agent.disabled_toolsets or [ ])) neverToolsets;
            message = "${opt}: browser, computer use, cron, kanban, connections and chat toolsets stay off.";
          }
          {
            assertion = (s.approvals.mode or null) != "off" && (s.approvals.unattended_mode or null) == "deny"
              && lib.all (c: lib.elem c (s.approvals.deny or [ ])) (denyCommands ++ inst.extraDenyCommands);
            message = "${opt}: approvals must stay on, unattended requests denied, and the deny list complete (every agent's list plus extraDenyCommands).";
          }
          {
            assertion = !(env ? HERMES_YOLO_MODE) && !(inst.secrets ? HERMES_YOLO_MODE)
              && !(lib.elem "--yolo" inst.extraArgs);
            message = "${opt}: YOLO mode bypasses approvals.";
          }
          {
            assertion = lib.all (v: !(lib.any (p: lib.hasPrefix p v) [ "TELEGRAM_" "DISCORD_" "SLACK_" "WHATSAPP_" "SIGNAL_" "MATRIX_" "MATTERMOST_" "EMAIL_" "TWILIO_" ]))
              (lib.attrNames env ++ lib.attrNames inst.secrets);
            message = "${opt}: messaging platforms stay off; chat belongs to OpenClaw.";
          }
          {
            assertion = lib.all (n: mcpAllowed ? ${n}) (lib.attrNames inst.mcpServers)
              && lib.all lib.id (lib.mapAttrsToList serverOk servers);
            message = "${opt}: MCP servers are only paperclip and jev, each running this role's own package with no url, headers or auth, sampling off, and only its own key from .env (\${PAPERCLIP_AGENT_KEY} or \${JEV_API_KEY}).";
          }
          {
            assertion = inst.jev.enable == (inst.secrets ? JEV_API_KEY)
              && (!inst.jev.enable || (inst.secrets.JEV_API_KEY == cfg.jev.keySecret && servers ? jev
                && lib.elem "jev" (s.platform_toolsets.api_server or [ ])));
            message = "${opt}: an agent with the Jev tool has its key from roles.hermesAgents.jev.keySecret and jev in its toolsets; one without has neither.";
          }
          {
            assertion = (claudeTyped != [ ]) == (inst.secrets ? ANTHROPIC_API_KEY)
              && (claudeTyped == [ ] || (cfg.anthropic.keySecret != null && inst.secrets.ANTHROPIC_API_KEY == cfg.anthropic.keySecret));
            message = "${opt}: the Anthropic key goes to an agent exactly when its model, fallbacks or side tasks use Claude, and comes from roles.hermesAgents.anthropic.keySecret.";
          }
          {
            assertion = (claudeRendered == [ ] || claudeTyped != [ ]) && lib.all (m: lib.elem m cfg.anthropic.models) claudeModels;
            message = "${opt}: Claude is used only through the typed model, fallbacks and side tasks, and only the models in roles.hermesAgents.anthropic.models (got ${toString claudeModels}).";
          }
          {
            assertion = lib.intersectLists anthropicForbidden (lib.attrNames env ++ lib.attrNames inst.secrets) == [ ];
            message = "${opt}: ${toString anthropicForbidden} stay unset: Claude runs only on the API key, against Anthropic's own endpoint.";
          }
          {
            assertion = (s.skills.project_discovery or true) == false && (s.skills.write_approval or false)
              && (s.cron.allow_agent_scheduling or true) == false && (s.security.allow_private_urls or true) == false;
            message = "${opt}: project skills, unapproved skill writes, agent scheduling and private URLs stay off.";
          }
        ]
        ++ common.pluginNameAssertions { cfg = inst; optionPath = opt; }
      ) names;

    users.groups = lib.mapAttrs' (name: inst: lib.nameValuePair (userOf name) { gid = inst.uid; }) instances;
    users.users = lib.mapAttrs' (name: inst: lib.nameValuePair (userOf name) {
      isSystemUser = true;
      uid = inst.uid;
      group = userOf name;
      home = stateDirOf name;
    }) instances;

    sops.secrets = lib.mkMerge (lib.mapAttrsToList (name: inst:
      lib.mapAttrs' (_: secret: lib.nameValuePair secret { }) inst.secrets
      // lib.optionalAttrs (inst.terminal.ssh != null) {
        ${inst.terminal.ssh.keySecret} = {
          owner = userOf name;
          path = "${stateDirOf name}/.ssh/id_ed25519";
          mode = "0400";
        };
      }) instances);

    sops.templates = lib.mapAttrs' (name: inst: lib.nameValuePair "hermes-${name}.env" {
      content = lib.concatStrings (lib.mapAttrsToList (var: secret: "${var}=${config.sops.placeholder.${secret}}\n") inst.secrets);
      restartUnits = [ "hermes-${name}.service" ];
    }) instances;

    # Directories: the state dir and HERMES_HOME belong to the user and are
    # setgid, so files root writes there (config.yaml) get the instance group.
    systemd.tmpfiles.rules = lib.concatLists (lib.mapAttrsToList (name: inst:
      let u = userOf name; home = "${stateDirOf name}/.hermes"; in
      [
        "d ${stateDirOf name} 2750 ${u} ${u} - -"
        "d ${home} 2750 ${u} ${u} - -"
        "d ${inst.workingDirectory} 2750 ${u} ${u} - -"
        "d ${stateDirOf name}/.ssh 0700 ${u} ${u} - -"
      ]
      ++ map (d: "d ${home}/${d} 2750 ${u} ${u} - -") common.stateSubdirs
      # known_hosts comes from the store, so ssh can't add the host's other
      # keys to it after login; the config stops it trying, which would
      # otherwise print a warning into every new connection's output.
      ++ lib.optionals (inst.terminal.ssh != null) [
        "L+ ${stateDirOf name}/.ssh/known_hosts - - - - ${pkgs.writeText "hermes-${name}-known-hosts" inst.terminal.ssh.knownHosts}"
        "L+ ${stateDirOf name}/.ssh/config - - - - ${pkgs.writeText "hermes-${name}-ssh-config" "UpdateHostKeys no\n"}"
      ]
    ) instances);

    system.activationScripts = lib.mapAttrs' (name: inst:
      let
        u = userOf name;
        home = "${stateDirOf name}/.hermes";
      in
      lib.nameValuePair "hermes-${name}" (lib.stringAfter ([ "users" ] ++ lib.optional (osConfig.system.activationScripts ? setupSecrets) "setupSecrets") ''
        install -d -m 2750 -o ${u} -g ${u} ${stateDirOf name} ${home} ${inst.workingDirectory}
        ${common.mkStateScript {
          inherit pkgs;
          cfg = inst;
          hermesHome = home;
          workingDirectory = inst.workingDirectory;
          owner = "root:${u}";
          stateDirs = common.stateSubdirs;
          modes = { config = "0640"; env = "0640"; managed = "0644"; auth = "0600"; document = "0640"; };
        }}
        chown ${u}:${u} ${lib.concatMapStringsSep " " (d: "${home}/${d}") common.stateSubdirs}
      '')) instances;

    systemd.services = lib.mapAttrs' (name: inst:
      let
        u = userOf name;
        others = map stateDirOf (lib.remove name names);
      in
      lib.nameValuePair "hermes-${name}" {
        description = "Hermes agent ${name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = { HOME = stateDirOf name; }
          // common.processEnvironment { hermesHome = "${stateDirOf name}/.hermes"; };
        # The ssh backend runs ssh and scp here, and syncs files by piping a
        # local `tar -c` into `tar -x` on the far side.
        path = common.processPath { inherit pkgs; cfg = inst; }
          ++ lib.optionals (inst.terminal.ssh != null) [ pkgs.openssh pkgs.gnutar ];
        restartTriggers = [ (builtins.toJSON inst.settings) inst.soul ];
        serviceConfig = {
          User = u;
          Group = u;
          WorkingDirectory = inst.workingDirectory;
          ExecStartPre = claudeCheck name;
          ExecStart = lib.escapeShellArgs (common.gatewayArgv inst);
          Restart = "on-failure";
          RestartSec = "10s";
          UMask = "0027";
          MemoryMax = inst.memory;
          TasksMax = 512;

          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ (stateDirOf name) ];
          # Secrets under /run/secrets stay reachable for the ssh key, whose
          # path links there; everything else in it is root-only or another
          # service's.
          InaccessiblePaths = [ "-/var/lib/sops-nix" "-/var/lib/paperclip" "-/var/lib/postgresql" ]
            ++ map (d: "-${d}") others;
          PrivateTmp = true;
          PrivateDevices = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectProc = "invisible";
          RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" ];
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
        };
      }) instances;
  };
}
