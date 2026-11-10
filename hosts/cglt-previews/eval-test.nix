# Used only by the cglt-previews flake checks: no real SOPS file, and an
# example deploy key (not a real one) so the deploy path is evaluated as it
# will run, on any machine.
{ lib, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/cglt-previews.yaml";
  sops.validateSopsFiles = lib.mkForce false;

  cgltPreviews.deploy.authorizedKeys = lib.mkForce [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvalTestOnlyNotARealKeyEvalTestOnlyNotARealKey eval-test"
  ];
}
