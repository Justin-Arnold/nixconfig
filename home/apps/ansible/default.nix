{ pkgs, ...}:
{
  imports =
    [
      ./nodes/checkmk.nix
      ./nodes/nocodb.nix
      ./nodes/omada-controller.nix
    ];
  home.packages = [
    pkgs.ansible
    pkgs.python3Packages.requests
  ];
  
  home.stateVersion = "25.05";

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}