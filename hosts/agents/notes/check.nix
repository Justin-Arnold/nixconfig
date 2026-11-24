# nix build .#checks.<system>.notes
{ pkgs }:
pkgs.runCommand "notes-tests"
  {
    nativeBuildInputs = [ pkgs.python3 pkgs.git pkgs.gitleaks ];
  }
  ''
    export HOME=$TMPDIR
    if ! python3 -I ${./test.py} ${./notes.py} ${./notes-scan.py} ${../../../modules/roles/hermes-agents/jev-mcp/server.py} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
