# nix build .#checks.<system>.board-bridge
{ pkgs }:
pkgs.runCommand "board-bridge-tests"
  {
    # The Python the service runs with, discord.py and all.
    nativeBuildInputs = [ (import ./python.nix { inherit pkgs; }) ];
  }
  ''
    if ! python3 -I ${./test.py} ${./board-bridge.py} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
