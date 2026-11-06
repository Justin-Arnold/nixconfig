# nix build .#checks.<system>.notifications-stack
{ pkgs }:
let
  alertaServer = import ./alerta-server.nix { inherit pkgs; };
  # The packages alertad runs with, the push plugin among them.
  alertad = pkgs.python3.withPackages (ps: [ (ps.toPythonModule alertaServer) ]);
in
pkgs.runCommand "notifications-stack-tests" { } ''
  if ! ${pkgs.python3}/bin/python3 -I ${./forwarder-test.py} ${./forwarder.py} >forwarder.log 2>&1; then
    cat forwarder.log
    exit 1
  fi
  if ! ${alertad}/bin/python3 -I ${./plugin-test.py} >plugin.log 2>&1; then
    cat plugin.log
    exit 1
  fi
  cat forwarder.log plugin.log | tee $out
''
