{ config, pkgs, sops-nix, ... }:{
  imports = [ 
    ./hardware-configuration.nix
    ../../modules/common
    ../../modules/profiles/server.nix
    ../../modules/platforms/nixos

    sops-nix.nixosModules.sops
  ];
  systemProfile = {
    hostname = "github-runner";
    stateVersion = "25.05";
    isServer = true;
  };

  sops.age.keyFile = "/home/justin/.config/sops/age/keys.txt";
  sops.defaultSopsFile = ../../secrets/secrets.yaml;

  sops.secrets."github/cglt_runner_token" = {};

  services.github-runners = {
    cglt-runner = {
      enable = true;
      name = "cglt-runner";
      tokenFile = config.sops.secrets."github/cglt_runner_token".path;
      url = "https://github.com/commongoodlt/CGLT-Monorepo";

      extraPackages = with pkgs; [
        nodejs_22
        pnpm_9
      ];
    };
  };
}