{ pkgs, config, ... }:
{
  imports = [
    ./systemProfile.nix
    ../platforms
    ../profiles
  ];
  ############################################################
  ## Identity
  ############################################################
  time.timeZone = config.systemProfile.timeZone;
  networking.hostName = config.systemProfile.hostname;

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

  programs.zsh.enable = true;

  ############################################################
  ## User Configuration
  ############################################################
  users.users."${config.systemProfile.username}" = {
    isNormalUser = true; 
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  #############################################################
  ## Fonts
  #############################################################
  fonts.packages = with pkgs; [
    nerd-fonts.fira-code
  ];

  programs.ssh.startAgent = true;
  programs.ssh.extraConfig = ''
    Host *
        AddKeysToAgent yes
        IdentitiesOnly yes
  '';
}