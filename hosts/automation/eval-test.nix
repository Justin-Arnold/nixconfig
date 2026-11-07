# Used only by the automation flake checks: no real SOPS file, so the full
# configuration and every assertion can be evaluated on any machine.
{ lib, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/automation.yaml";
  sops.validateSopsFiles = lib.mkForce false;
}
