# Used only by the dashboard flake checks: no real SOPS file, so the full
# configuration and every assertion can be evaluated on any machine.
{ lib, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/dashboard.yaml";
  sops.validateSopsFiles = lib.mkForce false;
}
