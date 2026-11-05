# Shared by the NixOS module and the flake check (which runs on macOS too).
{ pkgs, lib }:
rec {
  syncPackage = pkgs.writeShellApplication {
    name = "doppler-secrets-sync";
    runtimeInputs = [
      pkgs.age
      pkgs.coreutils
      pkgs.diffutils
      pkgs.doppler
      pkgs.gnused
      pkgs.jq
    ] ++ (if pkgs.stdenv.hostPlatform.isLinux then [ pkgs.util-linux ] else [ pkgs.flock ]);
    text = builtins.readFile ./sync.sh;
  };

  # outputs: list of { path, format, key, vars, static, owner, group, mode, restartServices }
  mkSpec = { outputs, validators ? { }, recipients ? [ ] }:
    let
      requiredKeys = lib.unique (lib.concatMap
        (o: if o.format == "raw" then [ o.key ] else lib.attrValues o.vars)
        outputs);
    in
    pkgs.writeText "doppler-secrets-spec.json" (builtins.toJSON {
      inherit requiredKeys validators recipients;
      outputs = map
        (o: {
          inherit (o) path format owner group mode vars static;
          key = o.key;
          restart = o.restartServices;
        })
        outputs;
    });
}
