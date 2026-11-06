# Apps that only exist on NixOS: Flatpak and the apps it installs. The
# options keep the shared modules.apps names; apps that work on both
# platforms live in modules/apps.
{ lib, ... }:

let
  nixFiles = builtins.filter
    (name: name != "default.nix" && lib.hasSuffix ".nix" name)
    (builtins.attrNames (builtins.readDir ./.));
in
{
  imports = map (f: ./. + "/${f}") nixFiles;
}
