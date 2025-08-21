{ pkgs, config, lib, ... }: {
  imports = [
    ./server.nix
    ./desktop.nix
  ];
}