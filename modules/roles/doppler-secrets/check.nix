# nix build .#checks.<system>.doppler-secrets
# Runs test.sh against the real lab118-services output layout.
{ pkgs, lib }:
let
  dopplerLib = import ./lib.nix { inherit pkgs lib; };
  layout = import ../../../hosts/lab118-services/doppler-secrets.nix;
  spec = dopplerLib.mkSpec {
    outputs = lib.attrValues layout.outputs;
    inherit (layout) validators;
  };
in
pkgs.runCommand "doppler-secrets-tests"
  {
    nativeBuildInputs = [ pkgs.age pkgs.bash pkgs.coreutils pkgs.diffutils pkgs.findutils pkgs.gnugrep pkgs.jq ];
  }
  ''
    if ! bash ${./test.sh} ${dopplerLib.syncPackage}/bin/doppler-secrets-sync ${spec} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
