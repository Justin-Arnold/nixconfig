{ config, pkgs, self, zen-browser, ... }:
{
  imports = [ 
    ../../modules/common
    ../../modules/platforms/darwin
  ];

  ############################################################
  ## System Profile
  ############################################################
  systemProfile = {
    hostname = "macbook16";
    stateVersionDarwin = 5;
    stateVersion = "24.05";
    hasGui = true;
    isDarwin = true;
    forCglt = true;
  };

  home-manager.users.justin = { ... }: {
    imports = [
      ../../home/roles/provisioning-runner.nix
    ];
  };
}
