{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.githubSsh;
in {
  options.services.githubSsh = {
    enable = mkEnableOption "GitHub SSH key generation";
  };

  config = mkIf cfg.enable {
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
  };
}
