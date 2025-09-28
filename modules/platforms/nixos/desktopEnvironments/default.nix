# Auto-import all .nix files in this directory except default.nix
{ lib, ... }:

let
  # Get all .nix files in current directory except default.nix
  nixFiles = builtins.filter 
    (name: name != "default.nix" && lib.hasSuffix ".nix" name)
    (builtins.attrNames (builtins.readDir ./.));
  
  # Convert filenames to paths
  modules = map (f: ./. + "/${f}") nixFiles;
in
{
  imports = modules;
}