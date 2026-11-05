# The Hermes agents on this host (roles.hermesAgents) and their models.
#
# Paperclip owns the work: it assigns issues, wakes an agent through its API
# server, and records what happened. Each agent reads and updates its issues
# through Paperclip's MCP server with its own key. None of them can change a
# running system; anything that would goes to the board as an approval.
#
# A new agent needs hermes/<name>/api-server-key in secrets/hosts/agents.yaml
# before the next switch, and hermes/<name>/ssh-key too if it works on
# workbench.
#
# Adding an agent's Paperclip key: create the key in Paperclip, put it in
# secrets/hosts/agents.yaml as hermes/<name>/paperclip-key, then add the name
# to withPaperclipKey. Until then the agent runs without Paperclip tools.
{ config, lib, pkgs, ... }:
let
  withPaperclipKey = [ "coordinator" "engineer" "researcher" "reviewer" "infra" ];

  paperclipKey = name:
    lib.optionalAttrs (lib.elem name withPaperclipKey) { PAPERCLIP_AGENT_KEY = "hermes/${name}/paperclip-key"; };

  # Codex through each agent's own ChatGPT login (a device code per agent, so
  # one agent's token refresh can't sign the others out). The account decides
  # which models it gets, and `sudo hermes-agent <name> model` lists them; quit
  # the picker without choosing. Each agent falls back a generation, so one
  # retired model doesn't stop its runs.
  codex = name: { provider = "openai-codex"; inherit name; };

  # Claude through the Anthropic API, on a key from the Console's Default
  # workspace (anthropic/api-key), capped only by the organization's spend
  # limit and credits. Only agents that name it get the key.
  claude = name: { provider = "anthropic"; inherit name; };

  # The lab's own model on inference's RTX 3090 (docs/inference/REFERENCE.md),
  # whatever model the server has loaded. Hermes falls back to Codex when
  # it's down or busy.
  local = { provider = "lab-gpu"; name = "local"; };

  # workbench, where the engineer's, reviewer's and infra's terminal and file
  # tools act. Its host key is `cat /etc/ssh/ssh_host_ed25519_key.pub` there,
  # null until it's installed; with it, each of them logs in as
  # agent-<name> with hermes/<name>/ssh-key and gets the terminal and file
  # toolsets.
  workbench = "10.0.0.153";
  workbenchHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG/RwXCbrj59Ofw70dbmSSFzna6cCONCChDX8q0mghrm";
  onWorkbench = workbenchHostKey != null;

  # The toolsets and terminal of an agent that works on workbench.
  onWorkbenchAs = name: {
    toolsets = [ "memory" "todo" "session_search" ] ++ lib.optionals onWorkbench [ "terminal" "file" ];
    terminal.ssh = if onWorkbench then {
      host = workbench;
      user = "agent-${name}";
      keySecret = "hermes/${name}/ssh-key";
      knownHosts = "${workbench} ${workbenchHostKey}";
      cwd = "/home/agent-${name}/work";
    } else null;
  };

  agents = config.roles.hermesAgents.instances;

  # Read-only lab tools (Proxmox, Beszel, Kuma, Alerta) for the coordinator,
  # infra and the researcher, and read-only GitHub for the coordinator and
  # the researcher (docs/agents/REFERENCE.md, "Lab state"). A source is on
  # once it's in observeReady, with its credential in
  # secrets/hosts/agents.yaml; Proxmox needs its nodes and CA here too.
  observeReady = [ "proxmox" "beszel" "kuma" "alerta" ];
  withGithubToken = true;
  # Two nodes, tried in turn (proxmox1 and proxmox8; proxmox2 is the GPU
  # node), and the cluster's CA certificate, /etc/pve/pve-root-ca.pem on any
  # node. Each node's certificate names its address.
  proxmoxNodes = [ "10.0.0.22" "10.0.0.101" ];
  proxmoxCa = ./proxmox-ca.pem;
  dashboard = "10.0.0.151";
  lab118 = "10.118.0.1";

  observe = config.roles.hermesAgents.observe;
  observing = lib.any (source: source != null) (lib.attrValues observe);
  observers = map (name: "hermes-${name}") (lib.attrNames (lib.filterAttrs (_: a: a.observe.enable) agents));
  hostOf = url: lib.head (lib.splitString ":" (lib.last (lib.splitString "://" url)));

  # Runs the hermes CLI as one agent, against that agent's state, e.g.
  # `sudo hermes-agent coordinator auth add openai-codex`.
  hermesAgentCli = pkgs.writeShellApplication {
    name = "hermes-agent";
    runtimeInputs = [ pkgs.util-linux ];
    text = ''
      known="${lib.concatStringsSep " " (lib.attrNames agents)}"
      if [ $# -lt 1 ] || [[ " $known " != *" $1 "* ]]; then
        echo "usage: hermes-agent <$known> <hermes arguments>" >&2
        exit 2
      fi
      name="$1"
      shift
      home="/var/lib/hermes-$name"
      # A prompt (-z, -q) runs in the agent's own gateway, in the folder this
      # command started from. The service can't see /home, so it refuses
      # anything started there (invalid_params); start from the agent's
      # workspace. --in still picks another folder.
      case "$name" in
      ${lib.concatStrings (lib.mapAttrsToList (n: inst: ''
        ${n}) cd ${lib.escapeShellArg inst.workingDirectory} ;;
      '') agents)}
      esac
      exec runuser -u "hermes-$name" -- env HOME="$home" HERMES_HOME="$home/.hermes" HERMES_MANAGED=true \
        ${lib.getExe' config.roles.hermesAgents.package "hermes"} "$@"
    '';
  };
in
{
  roles.hermesAgents = {
    enable = true;

    # inference's nginx knows this key as the client `agents`; the same value
    # is inference/keys/agents in secrets/hosts/inference.yaml.
    providers.lab-gpu = {
      baseUrl = "https://inference.servicestack.xyz/v1";
      keyEnv = "LAB_INFERENCE_KEY";
      keySecret = "inference/agents-key";
      # A slot's context, not the model's: llama-server gives each request 64K.
      models.local.contextLength = 65536;
    };

    # Session titles and the post-turn memory review, for every agent. The
    # review passed the model test (5/5), so it's local too.
    sideTasks = {
      title_generation = local;
      background_review = local;
    };

    anthropic.keySecret = "anthropic/api-key";

    # Jev, TypeSafe's decision model, as a tool for every agent; each SOUL.md
    # says when to use it. What they send it is text from Paperclip or public
    # sources only (docs/agents/REFERENCE.md).
    jev.enable = true;

    observe = {
      proxmox = if lib.elem "proxmox" observeReady && proxmoxNodes != [ ] && proxmoxCa != null then {
        urls = map (address: "https://${address}:8006") proxmoxNodes;
        caFile = proxmoxCa;
      } else null;
      beszel = if lib.elem "beszel" observeReady then {
        url = "https://beszel.servicestack.xyz";
        user = "hello+beszelagents@justin-arnold.com";
      } else null;
      # The status page made for the agents: every monitor, no links or tags.
      kuma = if lib.elem "kuma" observeReady then { url = "http://${lab118}:3002"; slug = "agents"; } else null;
      alerta = if lib.elem "alerta" observeReady then { url = "http://${lab118}:5000"; } else null;
    };

    instances = {
      # Paperclip's CEO: breaks objectives into issues and assigns them.
      coordinator = {
        uid = 3201;
        port = 8642;
        model = codex "gpt-6.1-sol";
        fallbacks = [ (codex "gpt-6-sol") (claude "claude-opus-5-5") ];
        soul = builtins.readFile ./souls/coordinator.md;
        secrets = paperclipKey "coordinator";
        observe.enable = observing;
        github.enable = withGithubToken;
      };

      # Writes code, on workbench once its host key is above.
      engineer = onWorkbenchAs "engineer" // {
        uid = 3202;
        port = 8643;
        model = codex "gpt-6.1-sol";
        fallbacks = [ (codex "gpt-6-sol") (claude "claude-opus-5-5") ];
        soul = builtins.readFile ./souls/engineer.md;
        secrets = paperclipKey "engineer";
      };

      # Reviews the engineer's and infra's pull requests when Paperclip hands
      # them over, on Claude, so code is read by a different model family
      # from the one that wrote it. It reads and tests on workbench, and
      # never pushes or changes a pull request; its verdict goes to
      # Paperclip and its findings to the PR as a comment.
      reviewer = onWorkbenchAs "reviewer" // {
        uid = 3204;
        port = 8645;
        model = claude "claude-opus-5-5";
        fallbacks = [ (claude "claude-sonnet-5-5") (codex "gpt-6.1-sol") ];
        soul = builtins.readFile ./souls/reviewer.md;
        secrets = paperclipKey "reviewer";
        extraDenyCommands = [ "git push*" "gh pr create*" "gh pr edit*" "gh pr close*" "gh pr ready*" ];
        settings.agent.reasoning_effort = "high";
      };

      # Prepares pull requests to nixconfig and checks them with Nix on
      # workbench. Switching a host stays with Justin.
      infra = onWorkbenchAs "infra" // {
        uid = 3205;
        port = 8646;
        model = codex "gpt-6.1-sol";
        fallbacks = [ (codex "gpt-6-sol") (claude "claude-opus-5-5") ];
        soul = builtins.readFile ./souls/infra.md;
        secrets = paperclipKey "infra";
        observe.enable = observing;
      };

      # Answers questions and writes them up, on the local model, with Codex's
      # middle tier behind it. Compression stays on Codex for now.
      researcher = {
        uid = 3203;
        port = 8644;
        model = local;
        fallbacks = [ (codex "gpt-6.1-terra") (codex "gpt-5.6-terra") ];
        auxiliary.compression = codex "gpt-6.1-terra";
        soul = builtins.readFile ./souls/researcher.md;
        secrets = paperclipKey "researcher";
        observe.enable = observing;
        github.enable = withGithubToken;
      };
    };
  };

  # The agents reach the Internet and this host, and nothing else on the LAN
  # unless it's listed in allow (modules/roles/agent-egress.nix).
  roles.agentEgress = {
    enable = true;
    users = map (name: "hermes-${name}") (lib.attrNames agents);
    allow = {
      # Every agent, for its side tasks.
      inference = { address = "10.0.0.63"; tcpPorts = [ 443 ]; };
    } // lib.optionalAttrs onWorkbench {
      # Only the agents whose terminal is there.
      workbench = {
        address = workbench;
        tcpPorts = [ 22 ];
        users = map (name: "hermes-${name}") (lib.attrNames (lib.filterAttrs (_: a: a.terminal.ssh != null) agents));
      };
    }
    # The lab tools' sources, only for the agents that have them.
    // lib.optionalAttrs (observe.proxmox != null) (lib.listToAttrs (lib.imap1 (i: url:
      lib.nameValuePair "proxmox-${toString i}" { address = hostOf url; tcpPorts = [ 8006 ]; users = observers; })
      observe.proxmox.urls))
    // lib.optionalAttrs (observe.beszel != null) {
      beszel = { address = dashboard; tcpPorts = [ 443 ]; users = observers; };
    }
    // lib.optionalAttrs (observe.kuma != null || observe.alerta != null) {
      # Kuma's status page and Alerta over the lab tunnel, and nothing else
      # there: Node-RED (1880) holds the Alerta key, and ntfy (8080) reaches
      # the phone.
      lab118 = {
        address = lab118;
        tcpPorts = lib.optional (observe.kuma != null) 3002 ++ lib.optional (observe.alerta != null) 5000;
        users = observers;
      };
    };
  };

  # The reviewer's verdict only means something if it can't change what it
  # reviews.
  assertions = [ {
    assertion = lib.all (c: lib.elem c agents.reviewer.settings.approvals.deny) [ "git push*" "gh pr create*" "gh pr edit*" ];
    message = "agents: the reviewer must not be able to push or change pull requests (its extraDenyCommands).";
  } {
    assertion = lib.all (a: a.address != lab118 || (lib.subtractLists [ 3002 5000 ] a.tcpPorts == [ ] && (a.udpPorts or [ ]) == [ ]))
      (lib.attrValues config.roles.agentEgress.allow);
    message = "agents: on lab118 the agents may reach only Kuma's status page (3002) and Alerta (5000).";
  } ];

  environment.systemPackages = [ hermesAgentCli ];
}
