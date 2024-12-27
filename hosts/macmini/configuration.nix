{ config, pkgs, self, zen-browser, ... }:

{

  imports =
    [ 
      ../../modules/common/ssh.nix
      ../../modules/common/secrets.nix
      ../../modules/darwin
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

  # networking.hosts = {
  #   "127.0.0.1" = [
  #     "localhost"
  #     "localhost.spectora.com"
  #     "agents-localhost.spectora.com"
  #     "client-localhost.spectora.com"
  #     "editor-localhost.spectora.com"
  #     "ui-localhost.spectora.com"
  #     "localhost.ssl"
  #     "next-localhost.spectora.com"
  #     "reports-localhost.spectora.com"
  #     "widgets-localhost.spectora.com"
  #     "www-localhost.spectora.com"
  #   ];
  # };
}
