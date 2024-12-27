{ config, pkgs, lib, ... }:

{
  imports = [
    ./zsh.nix
    ./github-ssh.nix
  ];

  environment.systemPackages = with pkgs; [
    git
    fira-code-nerdfont
  ];

  fonts.fonts = with pkgs; [
    (nerdfonts.override { fonts = [ "FiraCode" ]; })
  ];

  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "justin" ];
  };
  services.githubSsh.enable = true;
  programs.ssh.startAgent = true;
 
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
