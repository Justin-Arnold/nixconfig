# nix build .#checks.<system>.inference-eval
#
# Evaluates the example (eval-test.nix) once with each model in models.nix as
# the active one. `models` is the real host's roles.inference.models.
{ pkgs, lib, example, models }:
pkgs.writeText "inference-eval" (builtins.toJSON (lib.mapAttrs
  (name: _: builtins.unsafeDiscardStringContext (example.extendModules {
    modules = [ { roles.inference.active = lib.mkForce name; } ];
  }).config.system.build.toplevel.drvPath)
  models))
