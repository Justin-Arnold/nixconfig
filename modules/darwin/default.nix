{ config, pkgs, lib, ... }:

{
    imports = [
        ./dock.nix
        ./homebrew.nix
        ./ssh.nix
    ];
}
