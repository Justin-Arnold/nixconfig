# Each case breaks the automation host's exposure policy (configuration.nix),
# and evaluating the example (eval-test.nix) with it must fail. flake/checks.nix
# runs them as .#checks.<system>.automation-exposure-guards.
{ lib, example }:
let
  vhost = "automation.servicestack.xyz";
in
{
  extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 5678 ]; };
  extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
  interface-opening = { networking.firewall.interfaces.ens18.allowedTCPPorts = [ 5678 ]; };
  trusted-interface = { networking.firewall.trustedInterfaces = [ "ens18" ]; };
  n8n-open-firewall = { services.n8n.openFirewall = true; };
  n8n-on-all-interfaces = { services.n8n.environment.N8N_LISTEN_ADDRESS = lib.mkForce "0.0.0.0"; };
  n8n-reaches-lan = { systemd.services.n8n.serviceConfig.IPAddressAllow = lib.mkForce [ "localhost" "10.0.0.0/24" ]; };
  n8n-lan-not-denied = { systemd.services.n8n.serviceConfig.IPAddressDeny = lib.mkForce [ "192.168.0.0/16" ]; };
  n8n-runs-commands = { services.n8n.environment.NODES_EXCLUDE = lib.mkForce "[]"; };
  n8n-runs-code = { services.n8n.environment.NODES_EXCLUDE = lib.mkForce (builtins.toJSON [ "n8n-nodes-base.executeCommand" "n8n-nodes-base.localFileTrigger" ]); };
  n8n-reads-environment = { services.n8n.environment.N8N_BLOCK_ENV_ACCESS_IN_NODE = lib.mkForce false; };
  n8n-community-packages = { services.n8n.environment.N8N_COMMUNITY_PACKAGES_ENABLED = lib.mkForce true; };
  key-in-environment = { services.n8n.environment.N8N_ENCRYPTION_KEY = "0000"; };
  tunnel-reaches-ui = { services.nginx.virtualHosts.${vhost}.locations."/".extraConfig = lib.mkForce "allow 10.118.0.1;\ndeny all;\n"; };
  tunnel-reaches-other-webhook = { services.nginx.virtualHosts.${vhost}.locations."^~ /webhook/".extraConfig = "allow 10.118.0.1;\ndeny all;\n"; };
  lan-reaches-github-webhook = { services.nginx.virtualHosts.${vhost}.locations."= /webhook/github".extraConfig = lib.mkForce "allow 10.0.0.0/24;\nallow 10.118.0.1;\ndeny all;\n"; };
  lan-reaches-alerta-webhook = { services.nginx.virtualHosts.${vhost}.locations."= /webhook/alerta".extraConfig = lib.mkForce "allow 10.0.0.0/24;\nallow 10.118.0.1;\ndeny all;\nlimit_except POST { deny all; }\n"; };
  alerta-webhook-any-method = { services.nginx.virtualHosts.${vhost}.locations."= /webhook/alerta".extraConfig = lib.mkForce "allow 10.118.0.1;\ndeny all;\n"; };
  docker-enabled = { virtualisation.docker.enable = true; };
  sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
  backup-target-missing = { automation.backup.nfsDevice = lib.mkOverride 40 null; };
  beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
}
