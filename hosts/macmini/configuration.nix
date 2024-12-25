{ config, pkgs, self, zen-browser, ... }:

{

  imports =
    [ 
      ../../modules/common/homebrew.nix
    ];

  environment.systemPackages = [
    pkgs.alacritty
  ];

  # Default browser not currently working, I need a new solution or to manually run that command
  #system.activationScripts.extraActivation.text = ''
  #  softwareupdate --install-rosetta --agree-to-license
  #  "defaultbrowser browser"
  #'';

  networking.hostName = "macmini";

  time.timeZone = "America/New_York";

  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = 5;
}
