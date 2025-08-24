{ pkgs, ...}:
{
  imports =
    [
      ./nodes/checkmk.nix
    ];
  home.packages = [ pkgs.ansible ];
  
  home.stateVersion = "25.05";

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}