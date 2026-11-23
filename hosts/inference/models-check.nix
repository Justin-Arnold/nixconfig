# nix build .#checks.<system>.inference-eval
#
# Evaluates the host once with each model in models.nix as the active one.
# `host` is the real nixosConfigurations.inference.
{ pkgs, lib, host }:
pkgs.writeText "inference-eval" (builtins.toJSON (lib.mapAttrs
  (name: _: builtins.unsafeDiscardStringContext (host.extendModules {
    modules = [ { roles.inference.active = lib.mkForce name; } ];
  }).config.system.build.toplevel.drvPath)
  host.config.roles.inference.models))
