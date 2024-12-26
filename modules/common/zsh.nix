{ config, pkgs, ... }:

{
  users.defaultUserShell = pkgs.zsh;
  programs.zsh = {
    enable = true;
    # shellAliases = {
    #   rebuild = "nix run nix-darwin -- switch --flake ~/Code/personal/nixconfig --verbose";
    # };
  };
}
