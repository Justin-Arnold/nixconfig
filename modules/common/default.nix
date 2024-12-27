{ config, pkgs, lib, ... }:

{
  imports = [
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
  programs.ssh.startAgent = true;
 
  boot.kernelPackages = pkgs.linuxPackages_latest;
}
