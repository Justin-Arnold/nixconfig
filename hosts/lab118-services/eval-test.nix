# Used only by the `lab118-services-eval` and exposure-guard flake checks:
# documentation-range values, so the full configuration and every assertion
# can be evaluated without the real facts or the real SOPS file.
{ lib, ... }:
{
  lab118.facts = lib.mkForce {
    contaboInstanceId = "0";
    macAddress = "02:00:00:00:00:01";
    ipv4 = {
      address = "203.0.113.10";
      prefixLength = 24;
      gateway = "203.0.113.1";
    };
    ipv6 = {
      address = "2001:db8::10";
      prefixLength = 64;
      gateway = "fe80::1";
    };
    diskDevice = "/dev/disk/by-id/example-disk";
  };

  # Tunnel addresses come from configuration.nix; only the parts that are not
  # known yet are filled in here.
  lab118.wireguard = {
    enable = lib.mkForce true;
    routerPublicKey = lib.mkForce "tlNTKGgnHUNSxoLjhkiJJ4BOUKt3B3jLSbIMkXSu5Vk=";
  };

  sops.defaultSopsFile = lib.mkForce "/nonexistent/lab118-services.yaml";
  sops.validateSopsFiles = lib.mkForce false;
}
