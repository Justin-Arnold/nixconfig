# Used only by the agents flake checks: no real SOPS file, so the full
# configuration and every assertion can be evaluated on any machine.
{ lib, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/agents.yaml";
  sops.validateSopsFiles = lib.mkForce false;
}
