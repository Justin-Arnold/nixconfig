{ pkgs, ...}:
{
  imports =
    [
      ./nodes/checkmk.nix
      ./nodes/nocodb.nix
      ./nodes/omada-controller.nix
      ./nodes/pangonlin-public.nix
      ./nodes/pangolin-newt.nix
      ./nodes/github-runner.nix
      ./nodes/vikunja.nix
    ];
  home.packages = [
    pkgs.ansible
    pkgs.python3Packages.requests
  ];

  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;
}
