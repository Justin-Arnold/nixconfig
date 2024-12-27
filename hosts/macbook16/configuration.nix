{ config, pkgs, self, zen-browser, ... }:

{

  imports =
    [ 
      ../../modules/common/homebrew.nix
      ../../modules/common/dock.nix
    ];

  environment.systemPackages = [
    pkgs.alacritty
  ];

  # Default browser not currently working, I need a new solution or to manually run that command
  #system.activationScripts.extraActivation.text = ''
  #  softwareupdate --install-rosetta --agree-to-license
  #  "defaultbrowser browser"
  #'';
  programs.zsh.enable = true;
  
  networking.hostName = "macbook16";

  time.timeZone = "America/New_York";

  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  system.stateVersion = 5;

  # services.aerospace = {
  #   enable = true;
  #   # settings.start-at-login = true;
  # };
}

