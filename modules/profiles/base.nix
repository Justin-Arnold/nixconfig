{ pkgs, ... }: {
  ############################################################
  ## Identity
  ############################################################
  time.timeZone       = "America/New_York";

  ############################################################
  ## Nix and Flakes
  ############################################################
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.trusted-users = [ "justin" ];
  nixpkgs.config.allowUnfree = true;

  ############################################################
  ## System Packages
  ############################################################
  environment.systemPackages = with pkgs; [
    git     # for version control
  ];

  programs.zsh.enable = true;
}