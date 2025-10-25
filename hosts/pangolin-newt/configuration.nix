{ config, pkgs, sops-nix, ... }:

{
  imports =
    [ 
      ./hardware-configuration.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos

      sops-nix.nixosModules.sops
    ];

  environment.systemPackages = with pkgs; [
    fosrl-newt
  ];

  systemProfile = {
    hostname = "pangolin-newt";
    stateVersion = "25.05";
    isServer = true;
  };

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/secrets.yaml;

  sops.secrets."pangolin/newt/id" = {};
  sops.secrets."pangolin/newt/secret-key" = {};

  sops.templates."fosrl-newt.env" = {
    content = ''
      NEWT_ID=${config.sops.placeholder."pangolin/newt/id"}
      NEWT_SECRET=${config.sops.placeholder."pangolin/newt/secret-key"}
    '';
    mode = "0440";
    owner = "root";
    group = "keys";
  };

  systemd.services.fosrl-newt = {
    description = "FOSRL Newt Service";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      EnvironmentFile = config.sops.templates."fosrl-newt.env".path;
      
      ExecStart = pkgs.writeShellScript "fosrl-newt-start" ''
        exec ${pkgs.fosrl-newt}/bin/newt \
          --id "$NEWT_ID" \
          --secret "$NEWT_SECRET" \
          --endpoint https://tunnel.servicestack.xyz
      '';

      Restart = "always";
      RestartSec = "10s";
      
      DynamicUser = true;
      SupplementaryGroups = [ config.users.groups.keys.name ];
    };
  };
}