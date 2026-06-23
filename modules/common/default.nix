{ pkgs, config, ... }:
{
  imports = [
    ./systemProfile.nix
    ../apps
  ];
  ############################################################
  ## Identity
  ############################################################
  time.timeZone = config.systemProfile.timeZone;
  networking.hostName = config.systemProfile.hostname;
  networking.nameservers = [
    "10.0.0.1"
  ];

  services.resolved.enable = true;

  ############################################################
  ## Nix and Flakes
  ############################################################
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nix.settings.trusted-users = [
    config.systemProfile.username
  ];

  nixpkgs.config.allowUnfree = true;

  ############################################################
  ## System Packages
  ############################################################
  environment.systemPackages = with pkgs; [
    git
    _1password-cli
    sops
    age
  ];

  #############################################################
  ## Fonts
  #############################################################
  fonts.packages = with pkgs; [
    nerd-fonts.fira-code
  ];
}