{ config, pkgs, lib, home-manager, sops-nix, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../modules/common
    ../../modules/profiles
    ../../modules/platforms/nixos.nix
    ../../modules/roles/docker.nix

    sops-nix.nixosModules.sops
  ];

  systemProfile = {
    hostname = "onepassword-connect";
    stateVersion = "25.05";
    isServer = true;
  };

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";

  sops.secrets."onepassword.env" = {
    sopsFile = ../../secrets/onepassword.env;
    format = "dotenv";
    mode = "0400";
    owner = "justin";
    group = "users";
  };

  virtualisation.oci-containers.containers.onepassword-connect-api = {
    image = "1password/connect-api:latest";
    autoStart = true;
    ports = [
      "8080:8080"
    ];
    volumes = [
      "/home/justin/1password-credentials.json:/home/opuser/.op/1password-credentials.json"
      "data:/home/opuser/.op/data"
    ];
  };

  virtualisation.oci-containers.containers.onepassword-connect-sync = {
    image = "1password/connect-sync:latest";
    autoStart = true;
    ports = [
      "8081:8080"
    ];
    volumes = [
      "/home/justin/1password-credentials.json:/home/opuser/.op/1password-credentials.json"
      "data:/home/opuser/.op/data"
    ];
  };

  networking.firewall.allowedTCPPorts = [ 8080 8081 ];

  home-manager.users.justin = { ... }: {
    imports = [ 
      ../../home/roles/base.nix
      ../../home/apps/1password-connect.nix
    ];
  };
}