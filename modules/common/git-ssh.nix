{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.githubSsh;
in {


  services.githubSsh.enable = true;
  programs.ssh.startAgent = true;

  programs.git = {
    enable = true;
    userName  = "Justin Arnold";
    userEmail = "hello@justin-arnold.com";
  };

  options.services.githubSsh = {
    enable = mkEnableOption "GitHub SSH key generation";
  };

  config = mkIf cfg.enable {
    services.openssh = {
      enable = true;
      hostKeys = [
        {
          path = "/Users/justin/.ssh/ssh_host_rsa_key";
          type = "rsa";
          bits = 4096;
        }
        {
          path = "/Users/justin/.ssh/id_ed25519";
          type = "ed25519";
	  comment = "justin.arnold@programmer.net";
        }
      ];
    };
  };
 
}