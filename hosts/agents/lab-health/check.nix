# nix build .#checks.<system>.lab-health
{ pkgs }:
pkgs.runCommand "lab-health-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    if ! python3 -I ${./test.py} ${./lab-health.py} ${../../../modules/roles/hermes-agents/lab-mcp/server.py} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
