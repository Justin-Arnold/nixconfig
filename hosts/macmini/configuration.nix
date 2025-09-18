{ config, pkgs, self, zen-browser, ... }:

{
  imports = [ 
    ../../modules/common
    ../../modules/darwin
  ];

  ############################################################
  ## System Profile
  ############################################################
  systemProfile = {
    hostname = "macmini";
    stateVersionDarwin = 5;
    hasGui = true;
    isDarwin = true;
    forCglt = true;
  };
}
