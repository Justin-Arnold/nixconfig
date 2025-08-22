{ pkgs, ...}:
{
  imports =
    [
      ./nodes/ansible.nix
      ./nodes/ollama.nix
    ];

  home.stateVersion = "25.05";

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}