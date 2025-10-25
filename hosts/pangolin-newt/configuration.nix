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

  sops.secrets."pangolin/newt/id" = {
    mode = "0440";
  };
  
  sops.secrets."pangolin/newt/secret-key" = {
    mode = "0440";
  };

  systemd.services.fosrl-newt = {
    description = "FOSRL Newt Service";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];

    serviceConfig = {
      ExecStart = pkgs.writeShellScript "fosrl-newt-start" ''
        exec ${pkgs.fosrl-newt}/bin/fosrl-newt \
          --id $(cat ${config.sops.secrets."pangolin/newt/id".path}) \
          --secret $(cat ${config.sops.secrets."pangolin/newt/secret-key".path}) \
          --endpoint https://tunnel.servicestack.xyz
      '';
      Restart = "always";
      RestartSec = "10s";
      
      DynamicUser = true;
      SupplementaryGroups = [ config.users.groups.keys.name ];
    };
  };
}