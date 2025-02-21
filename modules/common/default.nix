{ config, pkgs, lib, ... }:

{
  imports = [];

  environment.systemPackages = with pkgs; [
    git
  ];

  fonts.packages = with pkgs; [
    nerd-fonts.fira-code
  ];
  

  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "justin" ];
  };
  programs.ssh.startAgent = true;
 
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
