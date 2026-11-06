# Alerta's server with our `push` plugin installed beside it, where its
# alerta.plugins entry point can find it. The notifications-stack role runs
# alertad and its bootstrap from this, and its check tests it.
{ pkgs }:
let
  alertaPush = pkgs.python3.pkgs.buildPythonPackage {
    pname = "alerta-push";
    version = "1.0";
    pyproject = true;
    src = ./alerta-push;
    build-system = [ pkgs.python3.pkgs.setuptools ];
    # It imports alerta, which is only there beside alertad.
    dontUsePythonImportsCheck = true;
  };
in
pkgs.alerta-server.overridePythonAttrs (old: {
  dependencies = old.dependencies ++ [ alertaPush ];
  passthru = (old.passthru or { }) // { inherit alertaPush; };
})
