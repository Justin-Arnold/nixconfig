# nix build .#checks.<system>.notes
{ pkgs }:
pkgs.runCommand "notes-tests"
  {
    nativeBuildInputs = [ pkgs.python3 pkgs.git pkgs.gitleaks pkgs.jq ];
  }
  ''
    export HOME=$TMPDIR
    status=0
    python3 -I ${./test.py} ${./notes.py} ${./notes-scan.py} ${../../../modules/roles/hermes-agents/jev-mcp/server.py} >log 2>&1 || status=1
    ${pkgs.bash}/bin/bash ${./mirror-test.sh} ${./notes-mirror.sh} >>log 2>&1 || status=1
    cat log
    [ $status -eq 0 ] || exit 1
    cp log $out
  ''
