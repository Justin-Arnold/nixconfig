# nix build .#checks.<system>.agent-watch
{ pkgs }:
pkgs.runCommand "agent-watch-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    if ! python3 -I ${./test.py} ${./agent-watch.py} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
