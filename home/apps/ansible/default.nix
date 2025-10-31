{ pkgs, ...}:
{
  imports =
    [
      ./nodes/checkmk.nix
      ./nodes/nocodb.nix
      ./nodes/omada-controller.nix
      ./nodes/pangonlin-public.nix
      ./nodes/pangolin-newt.nix
      ./nodes/pr-previews.nix
    ];
  home.packages = [
    pkgs.ansible
    pkgs.python3Packages.requests
  ];
  
  home.stateVersion = "25.05";

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}