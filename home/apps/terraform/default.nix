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
      ./nodes/omada-controller.nix
      ./nodes/pangolin-newt.nix
      ./nodes/github-runner.nix
      ./nodes/vikunja.nix
    ];

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}
