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
    hostname = "macmini";
    stateVersionDarwin = 5;
    stateVersion = "24.05";
    hasGui = true;
    isDarwin = true;
    forCglt = true;
  };
}
