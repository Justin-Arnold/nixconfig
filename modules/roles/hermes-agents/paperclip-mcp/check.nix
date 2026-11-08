# nix build .#checks.<system>.paperclip-mcp
{ pkgs }:
let
  server = pkgs.callPackage ./package.nix { };
in
pkgs.runCommand "paperclip-mcp-tests" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
  mkdir work
  ln -s ${server}/lib/node_modules work/node_modules
  cp ${./test.mjs} work/test.mjs
  cd work
  if ! node test.mjs ${server}/lib/run-id.mjs >log 2>&1; then
    cat log
    exit 1
  fi
  cat log
  cp log $out
''
