# nix build .#checks.<system>.lab-mcp
{ pkgs }:
let
  python = pkgs.python3.withPackages (ps: [ ps.mcp ]);
in
pkgs.runCommand "lab-mcp-tests" { nativeBuildInputs = [ python ]; } ''
  if ! python3 -I ${./test.py} ${./server.py} >log 2>&1; then
    cat log
    exit 1
  fi
  cat log
  cp log $out
''
