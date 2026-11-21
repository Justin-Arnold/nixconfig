# Each case breaks the agents host's exposure policy (configuration.nix), and
# evaluating the example (eval-test.nix) with it must fail. flake/checks.nix
# runs them as .#checks.<system>.agents-exposure-guards.
{ lib, example }:
let
  # The agents use no local model today, so the provider guards get
  # one here: inference's endpoint, as the agents had it.
  labGpu = {
    roles.hermesAgents.providers.lab-gpu = {
      baseUrl = "https://inference.servicestack.xyz/v1";
      keyEnv = "LAB_INFERENCE_KEY";
      keySecret = "inference/agents-key";
      models.local.contextLength = 65536;
    };
  };
  local = { provider = "lab-gpu"; name = "local"; };
  withLabGpu = module: { imports = [ labGpu module ]; };
  # The provider alone, with the researcher on it, has to evaluate,
  # or the cases that use it would pass on a typo.
  researcherOnLocal = {
    roles.hermesAgents.instances.researcher = {
      model = lib.mkForce local;
      auxiliary.compression = { provider = "openai-codex"; name = "gpt-6.1-terra"; };
    };
  };
  labGpuEvaluates = (builtins.tryEval (example.extendModules {
    modules = [ labGpu researcherOnLocal ];
  }).config.system.build.toplevel.drvPath).success;
  vhost = "paperclip.servicestack.xyz";
  triggers = "paperclip-triggers.servicestack.xyz";
  fire = ''~ "^/api/routine-triggers/public/(?<trigger>[0-9a-f]{24})/fire$"'';
in
assert lib.assertMsg labGpuEvaluates
  "agents exposure guards: the agents host doesn't evaluate with the test-only lab-gpu provider, so the cases using it prove nothing";
{
  triggers-from-lan = { services.nginx.virtualHosts.${triggers}.locations.${fire}.extraConfig = lib.mkForce "allow 10.0.0.0/24;\ndeny all;\nlimit_except POST { deny all; }\n"; };
  triggers-any-method = { services.nginx.virtualHosts.${triggers}.locations.${fire}.extraConfig = lib.mkForce "allow 10.0.0.155;\ndeny all;\n"; };
  triggers-extra-location = { services.nginx.virtualHosts.${triggers}.locations."/api/".proxyPass = "http://127.0.0.1:3100"; };
  triggers-root-proxied = { services.nginx.virtualHosts.${triggers}.locations."/" = { return = lib.mkForce null; proxyPass = "http://127.0.0.1:3100"; }; };
  triggers-passes-query = { services.nginx.virtualHosts.${triggers}.locations.${fire}.proxyPass = lib.mkForce "http://127.0.0.1:3100"; };
  unguarded-with-variable = { services.nginx.virtualHosts."other.servicestack.xyz".locations."/".proxyPass = "http://127.0.0.1:3100$uri"; };
  extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 3100 ]; };
  extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
  interface-opening = { networking.firewall.interfaces.podman0.allowedTCPPorts = [ 3100 ]; };
  trusted-interface = { networking.firewall.trustedInterfaces = [ "podman0" ]; };
  docker-enabled = { virtualisation.docker.enable = true; };
  paperclip-published = { virtualisation.oci-containers.containers.paperclip.ports = [ "3100:3100" ]; };
  paperclip-on-all-interfaces = { virtualisation.oci-containers.containers.paperclip.environment.HOST = lib.mkForce "0.0.0.0"; };
  paperclip-bridged = { virtualisation.oci-containers.containers.paperclip.extraOptions = lib.mkForce [ ]; };
  socket-in-paperclip = { virtualisation.oci-containers.containers.paperclip.volumes = [ "/run/podman/podman.sock:/run/podman/podman.sock" ]; };
  local-trusted = { virtualisation.oci-containers.containers.paperclip.environment.PAPERCLIP_DEPLOYMENT_MODE = lib.mkForce "local_trusted"; };
  public-exposure = { virtualisation.oci-containers.containers.paperclip.environment.PAPERCLIP_DEPLOYMENT_EXPOSURE = lib.mkForce "public"; };
  telemetry-on = { virtualisation.oci-containers.containers.paperclip.environment.PAPERCLIP_TELEMETRY_DISABLED = lib.mkForce "0"; };
  secret-in-environment = { roles.paperclip.environment.BETTER_AUTH_SECRET = "0000"; };
  plain-http-public-url = { roles.paperclip.publicUrl = lib.mkForce "http://paperclip.servicestack.xyz"; };
  postgres-on-network = { services.postgresql.enableTCPIP = lib.mkForce true; };
  guard-missing = { services.nginx.virtualHosts.${vhost}.extraConfig = lib.mkForce ""; };
  location-shadows-guard = { services.nginx.virtualHosts.${vhost}.locations."^~ /mcp".proxyPass = "http://127.0.0.1:3100"; };
  sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
  backup-target-missing = { agents.backup.nfsDevice = lib.mkOverride 40 null; };
  beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
  bridge-reaches-lan = { systemd.services.board-bridge.serviceConfig.IPAddressDeny = lib.mkForce [ "10.0.0.0/8" ]; };
  bridge-allows-lan = { systemd.services.board-bridge.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
  events-allows-lan = { systemd.services.paperclip-events.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
  events-reaches-internet = { systemd.services.paperclip-events.serviceConfig.IPAddressDeny = lib.mkForce [ "10.0.0.0/8" ]; };
  lab-health-allows-lan = { systemd.services.lab-health.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
  lab-health-reaches-internet = { systemd.services.lab-health.serviceConfig.IPAddressDeny = lib.mkForce [ "10.0.0.0/8" ]; };
  lab-health-dry-run-allows-lan = { systemd.services.lab-health-dry-run.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
  hermes-api-on-all-interfaces = { roles.hermesAgents.instances.coordinator.environment.API_SERVER_HOST = lib.mkForce "0.0.0.0"; };
  hermes-duplicate-port = { roles.hermesAgents.instances.engineer.port = lib.mkForce 8642; };
  hermes-machine-tools-here = { roles.hermesAgents.instances.coordinator.toolsets = [ "terminal" ]; };
  hermes-backend-override = { roles.hermesAgents.instances.engineer.settings.terminal.backend = "docker"; };
  hermes-credentials-to-terminal = { roles.hermesAgents.instances.engineer.settings.terminal.credential_files = [ "auth.json" ]; };
  hermes-browser = { roles.hermesAgents.instances.researcher.toolsets = [ "browser" ]; };
  hermes-builtin-web = { roles.hermesAgents.instances.researcher.toolsets = [ "web" ]; };
  websearch-remote = { roles.hermesAgents.web.searxngUrl = lib.mkForce "https://search.example.org"; };
  websearch-lan = { roles.hermesAgents.web.searxngUrl = lib.mkForce "http://10.0.0.152:8888"; };
  websearch-extra-env = { roles.hermesAgents.instances.researcher.mcpServers.websearch.env.HERMES_ALLOW_PRIVATE_URLS = "1"; };
  websearch-without-flag = { roles.hermesAgents.instances.coordinator.mcpServers.websearch = { command = "/bin/true"; }; };
  searxng-on-all-interfaces = { services.searx.settings.server.bind_address = lib.mkForce "0.0.0.0"; };
  searxng-firewall = { services.searx.openFirewall = true; };
  hermes-approvals-off = { roles.hermesAgents.instances.engineer.settings.approvals.mode = "off"; };
  hermes-deny-list-dropped = { roles.hermesAgents.instances.engineer.settings.approvals.deny = [ ]; };
  hermes-allowlist-widened = { roles.hermesAgents.instances.engineer.settings.command_allowlist = [ "git rm *" "rm *" ]; };
  hermes-yolo = { roles.hermesAgents.instances.engineer.extraArgs = [ "--yolo" ]; };
  hermes-messaging = { roles.hermesAgents.instances.coordinator.secrets.TELEGRAM_BOT_TOKEN = "hermes/coordinator/telegram"; };
  hermes-extra-mcp = { roles.hermesAgents.instances.coordinator.mcpServers.shell.command = "/bin/sh"; };
  hermes-mcp-inline-key = { roles.hermesAgents.instances.coordinator.mcpServers.paperclip = { command = "x"; env.PAPERCLIP_API_KEY = "plaintext"; }; };
  hermes-project-skills = { roles.hermesAgents.instances.coordinator.settings.skills.project_discovery = true; };
  egress-off = { roles.agentEgress.enable = lib.mkForce false; };
  egress-misses-agent = { roles.agentEgress.users = lib.mkForce [ "hermes-coordinator" "hermes-engineer" ]; };
  egress-allows-range = { roles.agentEgress.allow.lan = { address = "10.0.0.0/24"; tcpPorts = [ 22 ]; }; };
  egress-allows-whole-host = { roles.agentEgress.allow.nas.address = "10.0.0.20"; };
  egress-allows-unknown-user = { roles.agentEgress.allow.inference = lib.mkForce { address = "10.0.0.63"; tcpPorts = [ 443 ]; users = [ "justin" ]; }; };
  provider-plain-http = withLabGpu { roles.hermesAgents.providers.lab-gpu.baseUrl = lib.mkForce "http://10.0.0.63:8080/v1"; };
  provider-reserved-name = { roles.hermesAgents.providers.local = { baseUrl = "https://inference.servicestack.xyz/v1"; keyEnv = "LOCAL_KEY"; keySecret = "inference/agents-key"; models.local.contextLength = 65536; }; };
  provider-short-context = withLabGpu { roles.hermesAgents.providers.lab-gpu.models.local.contextLength = lib.mkForce 32768; };
  provider-inline-key = { roles.hermesAgents.instances.coordinator.settings.providers.lab-gpu.api_key = "a-literal-key"; };
  provider-key-command = { roles.hermesAgents.instances.coordinator.settings.providers.lab-gpu.key_cmd = "cat /run/secrets/x"; };
  provider-added-plain-http = { roles.hermesAgents.instances.coordinator.settings.providers.other = { base_url = "http://10.0.0.63:8080/v1"; key_env = "LAB_INFERENCE_KEY"; }; };
  side-task-inline-key = { roles.hermesAgents.instances.engineer.settings.auxiliary.title_generation.api_key = "a-literal-key"; };
  side-task-own-endpoint = { roles.hermesAgents.instances.engineer.settings.auxiliary.background_review.base_url = "http://10.0.0.63:8080/v1"; };
  fallback-inline-key = { roles.hermesAgents.instances.researcher.settings.fallback_providers = [ { provider = "lab-gpu"; model = "local"; api_key = "a-literal-key"; } ]; };
  provider-key-not-from-sops = withLabGpu { roles.hermesAgents.instances.coordinator.secrets.LAB_INFERENCE_KEY = lib.mkForce "hermes/coordinator/paperclip-key"; };
  provider-unlisted-model = withLabGpu { roles.hermesAgents.instances.researcher.model = lib.mkForce { provider = "lab-gpu"; name = "qwen3.6-35b-a3b"; }; };
  compression-local = withLabGpu { roles.hermesAgents.instances.coordinator.auxiliary.compression = local; };
  compression-follows-local-model = withLabGpu { roles.hermesAgents.instances.researcher = { model = lib.mkForce local; auxiliary = lib.mkForce { }; }; };
  claude-key-on-researcher = { roles.hermesAgents.instances.researcher.secrets.ANTHROPIC_API_KEY = "anthropic/api-key"; };
  claude-oauth-token = { roles.hermesAgents.instances.coordinator.secrets.CLAUDE_CODE_OAUTH_TOKEN = "anthropic/api-key"; };
  claude-token-in-environment = { roles.hermesAgents.instances.engineer.environment.ANTHROPIC_TOKEN = "x"; };
  claude-other-endpoint = { roles.hermesAgents.instances.coordinator.environment.ANTHROPIC_BASE_URL = "https://proxy.example.com"; };
  claude-through-settings = { roles.hermesAgents.instances.researcher.settings.fallback_providers = [ { provider = "anthropic"; model = "claude-opus-5-5"; } ]; };
  claude-model-not-listed = { roles.hermesAgents.instances.coordinator.fallbacks = lib.mkForce [ { provider = "anthropic"; name = "claude-fable-5-1"; } ]; };
  claude-without-key = { roles.hermesAgents.anthropic.keySecret = lib.mkForce null; };
  jev-key-names-anthropic = { roles.hermesAgents.instances.coordinator.mcpServers.jev.env.JEV_API_KEY = lib.mkForce "\${ANTHROPIC_API_KEY}"; };
  jev-inline-key = { roles.hermesAgents.instances.coordinator.mcpServers.jev.env.JEV_API_KEY = lib.mkForce "a-literal-key"; };
  paperclip-takes-other-key = { roles.hermesAgents.instances.coordinator.mcpServers.paperclip.env.X = "\${LAB_INFERENCE_KEY}"; };
  jev-args-take-key = { roles.hermesAgents.instances.engineer.mcpServers.jev.args = [ "\${env:PAPERCLIP_AGENT_KEY}" ]; };
  jev-runs-shell = { roles.hermesAgents.instances.engineer.mcpServers.jev.command = lib.mkForce "/bin/sh"; };
  jev-remote = { roles.hermesAgents.instances.researcher.mcpServers.jev.url = "https://jev.example.com/mcp"; };
  mcp-sampling-on = { roles.hermesAgents.instances.coordinator.mcpServers.paperclip.sampling.enabled = lib.mkForce true; };
  jev-plain-http = { roles.hermesAgents.jev.baseUrl = lib.mkForce "http://10.0.0.63:8080/v1"; };
  jev-key-not-from-sops = { roles.hermesAgents.instances.researcher.secrets.JEV_API_KEY = lib.mkForce "hermes/researcher/paperclip-key"; };
  jev-key-without-tool = { roles.hermesAgents.instances.researcher = { jev.enable = lib.mkForce false; secrets.JEV_API_KEY = "jev/api-key"; }; };
  reviewer-may-push = { roles.hermesAgents.instances.reviewer.extraDenyCommands = lib.mkForce [ ]; };
  # The engineer has no extras, so its list is exactly every agent's.
  # settings merges with recursiveUpdate, so this list replaces the
  # reviewer's (and mkForce would land in it as a value).
  reviewer-extras-dropped = { roles.hermesAgents.instances.reviewer.settings.approvals.deny = example.config.roles.hermesAgents.instances.engineer.settings.approvals.deny; };
  claude-key-not-from-sops-on-reviewer = { roles.hermesAgents.instances.reviewer.secrets.ANTHROPIC_API_KEY = lib.mkForce "jev/api-key"; };
  lab-takes-other-key = { roles.hermesAgents.instances.researcher.mcpServers.lab.env.X = "\${PAPERCLIP_AGENT_KEY}"; };
  lab-key-without-tools = { roles.hermesAgents.instances.engineer.secrets.LAB_PROXMOX_TOKEN = "observe/proxmox-token"; };
  lab-key-not-from-sops = { roles.hermesAgents.instances.infra.secrets.LAB_ALERTA_KEY = lib.mkForce "agent-watch/alerta-key"; };
  lab-plain-http-proxmox = { roles.hermesAgents.observe.proxmox = lib.mkOverride 40 { urls = [ "http://10.0.0.14:8006" ]; caFile = ./proxmox-ca.pem; }; };
  lab-plain-http-off-tunnel = { roles.hermesAgents.observe.kuma = lib.mkOverride 40 { url = "http://10.0.0.5:3002"; slug = "agents"; }; };
  egress-to-node-red = { roles.agentEgress.allow.lab118.tcpPorts = lib.mkForce [ 3002 5000 1880 ]; };
  github-writable = { roles.hermesAgents.instances.researcher.mcpServers.github.args = [ "--read-only=false" ]; };
  github-token-not-from-sops = { roles.hermesAgents.instances.coordinator.secrets.GITHUB_OBSERVE_TOKEN = lib.mkForce "jev/api-key"; };
  github-through-settings = { roles.hermesAgents.instances.engineer.settings.mcp_servers.github.command = "github-mcp-server"; };
}
