{ config, pkgs, lib, ... }:

{
    imports = [
        ./users.nix
        ./ssh.nix
    ];
}
