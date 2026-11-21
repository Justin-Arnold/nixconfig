# Each case breaks workbench's exposure policy (configuration.nix), and
# evaluating the example (eval-test.nix) with it must fail. flake/checks.nix
# runs them as .#checks.<system>.workbench-exposure-guards.
{ lib, example }:
{
  extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 8080 ]; };
  extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
  interface-opening = { networking.firewall.interfaces.podman0.allowedTCPPorts = [ 8080 ]; };
  trusted-interface = { networking.firewall.trustedInterfaces = [ "podman0" ]; };
  docker-enabled = { virtualisation.docker.enable = true; };
  docker-socket = { virtualisation.podman.dockerSocket.enable = true; };
  agent-in-wheel = { users.users.agent-engineer.extraGroups = [ "wheel" ]; };
  agent-sudo-rule = { security.sudo.extraRules = [ { users = [ "agent-engineer" ]; commands = [ "ALL" ]; } ]; };
  agent-nix-trusted = { nix.settings.trusted-users = [ "agent-engineer" ]; };
  everyone-nix-trusted = { nix.settings.trusted-users = [ "*" ]; };
  nix-sandbox-off = { nix.settings.sandbox = lib.mkForce false; };
  egress-off = { roles.agentEgress.enable = lib.mkForce false; };
  egress-misses-agent = { users.users.agent-stray = { isNormalUser = true; uid = 3399; }; };
  egress-misses-builds = { roles.agentEgress.groups = lib.mkForce [ ]; };
  key-from-anywhere = { users.users.agent-engineer.openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILoose loose" ]; };
  key-with-forwarding = { users.users.agent-engineer.openssh.authorizedKeys.keys = [ ''restrict,port-forwarding,from="10.0.0.152" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILoose loose'' ]; };
  sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
  beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
}
