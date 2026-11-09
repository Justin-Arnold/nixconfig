# Test-only: never imported by the deployed host.
{ lib, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/home-assistant.yaml";
  sops.validateSopsFiles = lib.mkForce false;
}
