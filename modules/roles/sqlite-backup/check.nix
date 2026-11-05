# nix build .#checks.<system>.sqlite-backup
{ pkgs, lib }:
let
  backupLib = import ./lib.nix { inherit pkgs lib; };
in
pkgs.runCommand "sqlite-backup-tests"
  {
    nativeBuildInputs = with pkgs; [ age bash coreutils diffutils findutils gnugrep gnutar jq sqlite zstd ];
  }
  ''
    if ! bash ${./test.sh} ${backupLib.package}/bin/sqlite-backup >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
