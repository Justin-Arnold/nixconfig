# Used only by the workbench flake checks: no real SOPS file, and example
# values for what isn't set up yet, so the full configuration and every
# assertion can be evaluated on any machine.
{ lib, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/workbench.yaml";
  sops.validateSopsFiles = lib.mkForce false;

  workbench.github = lib.mkForce {
    login = "example-agents";
    email = "1+example-agents@users.noreply.github.com";
  };
  workbench.agents.engineer.publicKey = lib.mkForce
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample hermes-engineer@agents";
}
