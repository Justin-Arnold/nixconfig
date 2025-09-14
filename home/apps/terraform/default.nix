{ pkgs, ...}:
{
  imports =
    [
      ./nodes/ansible.nix
      ./nodes/ollama.nix
      ./nodes/checkmk.nix
      ./nodes/pangolin-public.nix
      ./nodes/nocodb.nix
      ./nodes/1password-connect.nix
    ];

  home.stateVersion = "25.05";

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}