# Each case breaks the dashboard's exposure policy (configuration.nix), and
# evaluating the example (eval-test.nix) with it must fail. flake/checks.nix
# runs them as .#checks.<system>.dashboard-exposure-guards.
{ lib, example }:
let
  lanVhost = "dashboard.servicestack.xyz";
in
{
  homarr-on-all-interfaces = { roles.homarr.hostBind = lib.mkForce "0.0.0.0"; };
  extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 7575 ]; };
  extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
  interface-opening = { networking.firewall.interfaces.docker0.allowedTCPPorts = [ 8090 ]; };
  trusted-interface = { networking.firewall.trustedInterfaces = [ "docker0" ]; };
  hub-listens-publicly = { services.beszel.hub.host = lib.mkForce "0.0.0.0"; };
  mcp-unguarded-in-lan = { services.nginx.virtualHosts.${lanVhost}.extraConfig = lib.mkForce ""; };
  pangolin-reaches-hub-admin = { services.nginx.virtualHosts."beszel.servicestack.xyz".locations."^~ /_/".extraConfig = lib.mkForce "allow 10.0.0.0/24;\ndeny all;\n"; };
  pangolin-reaches-agent-endpoint = { services.nginx.virtualHosts."beszel.servicestack.xyz".locations."= /api/beszel/agent-connect".extraConfig = lib.mkForce "allow 10.0.0.0/24;\ndeny all;\n"; };
  location-shadows-guard = { services.nginx.virtualHosts.${lanVhost}.locations."^~ /api/".proxyPass = "http://127.0.0.1:7575"; };
  docker-socket-in-homarr = { virtualisation.oci-containers.containers.homarr.volumes = [ "/var/run/docker.sock:/var/run/docker.sock" ]; };
  docker-api-enabled = { roles.homarr.environment.ENABLE_DOCKER = "true"; };
  key-in-environment = { roles.homarr.environment.SECRET_ENCRYPTION_KEY = "0000000000000000000000000000000000000000000000000000000000000000"; };
  hawser-agent-enabled = { roles.docker.dockhandManaged.enable = lib.mkForce true; };
  sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
  backup-target-missing = { dashboard.backup.nfsDevice = lib.mkOverride 40 null; };
  beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
}
