# nix build .#checks.<system>.paperclip-events
{ pkgs }:
pkgs.runCommand "paperclip-events-tests"
  {
    nativeBuildInputs = [ (import ./python.nix { inherit pkgs; }) ];
  }
  ''
    if ! python3 -I ${./test.py} ${./paperclip-events.py} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
