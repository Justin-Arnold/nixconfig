# nix build .#checks.<system>.jev-mcp
{ pkgs }:
let
  # The Python the server runs with, MCP SDK and all.
  inherit (pkgs.callPackage ./package.nix { }) python;
in
pkgs.runCommand "jev-mcp-tests" { nativeBuildInputs = [ python ]; } ''
  if ! python3 -I ${./test.py} ${./server.py} >log 2>&1; then
    cat log
    exit 1
  fi
  cat log
  cp log $out
''
