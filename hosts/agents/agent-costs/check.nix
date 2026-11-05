# nix build .#checks.<system>.agent-costs
{ pkgs }:
pkgs.runCommand "agent-costs-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    if ! python3 -I ${./test.py} ${./agent-costs.py} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
