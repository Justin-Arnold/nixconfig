{ config, lib, pkgs, ... }:

{
  services.openssh = {
    enable = true;
    hostKeys = [
      {
        path = "/home/justin/.ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
      {
        path = "/home/justin/.ssh/id_ed25519";
        type = "ed25519";
  comment = "justin.arnold@programmer.net";
      }
    ];
  };
}
