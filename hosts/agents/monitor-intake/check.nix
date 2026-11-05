# nix build .#checks.<system>.monitor-intake
{ pkgs }:
pkgs.runCommand "monitor-intake-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    if ! python3 -I ${./test.py} ${./monitor-intake.py} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
