{ pkgs, ...}:
{
  imports =
    [
      ./nodes/ansible.nix
      ./nodes/ollama.nix
      ./nodes/checkmk.nix
      ./nodes/pangolin-public.nix
    ];

  home.stateVersion = "25.05";

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}