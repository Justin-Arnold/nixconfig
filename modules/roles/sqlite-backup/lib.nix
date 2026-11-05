# Shared by the NixOS module and the flake check (which runs on macOS too).
{ pkgs, lib }:
{
  package = pkgs.writeShellApplication {
    name = "sqlite-backup";
    runtimeInputs = [
      pkgs.age
      pkgs.coreutils
      pkgs.curl
      pkgs.diffutils
      pkgs.findutils
      pkgs.gnutar
      pkgs.jq
      pkgs.sqlite
      pkgs.zstd
    ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.util-linux ];
    text = builtins.readFile ./sqlite-backup.sh;
  };

  mkSpec = spec: pkgs.writeText "sqlite-backup-spec.json" (builtins.toJSON spec);
}
