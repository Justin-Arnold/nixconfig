{ config, pkgs, ... }:

{
  imports = [
    # ./gnome.nix
  ];
  
  users.defaultUserShell = pkgs.zsh;
  programs.zsh.enable = true;
}
