# Each case breaks lab118-services' exposure policy (configuration.nix), and
# evaluating the example (eval-test.nix) with it must fail. flake/checks.nix
# runs them as .#checks.<system>.lab118-services-exposure-guards.
{ lib, example }:
{
  container-port-on-all-interfaces = { virtualisation.oci-containers.containers.uptime-kuma.ports = lib.mkForce [ "3001:3001" ]; };
  node-red-published-publicly = { roles.notificationsStack.nodeRed.hostBind = "0.0.0.0"; };
  extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 5000 ]; };
  extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
  hawser-agent-enabled = { roles.docker.dockhandManaged.enable = lib.mkForce true; };
  beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
  incomplete-facts = { lab118.facts = lib.mkOverride 40 ((import ./facts.nix) // { diskDevice = null; }); };
  github-intake-any-method = { services.nginx.virtualHosts."intake.lab118.xyz".locations."= /github".extraConfig = lib.mkForce "proxy_pass https://$automation/webhook/github;\nproxy_ssl_verify on;\n"; };
  github-intake-unverified = { services.nginx.virtualHosts."intake.lab118.xyz".locations."= /github".extraConfig = lib.mkForce "limit_except POST { deny all; }\nproxy_pass https://$automation/webhook/github;\nproxy_ssl_verify off;\n"; };
}
