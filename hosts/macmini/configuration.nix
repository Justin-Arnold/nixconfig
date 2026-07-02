{ config, pkgs, inputs, zen-browser, p99, ... }:

{
  imports = [ 
    ../../modules/common
    ../../modules/platforms/darwin
    
    p99.darwinModules.default
  ];

  ############################################################
  ## System Profile
  ############################################################
  systemProfile = {
    hostname = "macmini";
    stateVersionDarwin = 5;
    stateVersion = "24.05";
    hasGui = true;
    isDarwin = true;
    forCglt = true;
  };

  modules = {
    apps = {
      godot = {
        enable = true;
      };
      zoxide = {
        enable = true;
        replaceCd = true;
      };
    };
  };
  home-manager.users.justin = { ... }: {
    imports = [
      ../../home/roles/provisioning-runner.nix
    ];
  };

  programs.p99 = {
    enable = false;
    enableCompletions = false;
  };
}
