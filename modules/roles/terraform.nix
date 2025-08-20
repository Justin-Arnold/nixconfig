{ pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    terraform  # Infrastructure as Code tool
    direnv     # Environment switcher for the shell
    nix-direnv # direnv integration for nix
  ];
  programs.direnv.enable = true;
}