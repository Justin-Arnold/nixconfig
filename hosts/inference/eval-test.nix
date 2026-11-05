# Used only by the inference flake checks: no real SOPS file, so the full
# configuration and every assertion can be evaluated on any machine.
{ lib, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/inference.yaml";
  sops.validateSopsFiles = lib.mkForce false;
}
