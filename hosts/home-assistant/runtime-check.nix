# Packages/config only: no host build, service startup, radios or secrets.
{ pkgs, host }:
let
  ha = pkgs.home-assistant.override {
    extraComponents = host.config.services.home-assistant.extraComponents;
  };
  py = ha.python3Packages.python.withPackages (ps: [
    (ps.toPythonModule ha)
    ps.colorlog
  ]);
in
pkgs.runCommand "home-assistant-runtime" { } ''
  export HOME=$TMPDIR
  ${pkgs.python-matter-server}/bin/matter-server --help > matter-help.txt
  export PYTHONPATH=${host.config.systemd.services.home-assistant.environment.PYTHONPATH}
  grep -q -- '--listen-address' matter-help.txt
  grep -q -- '--primary-interface' matter-help.txt
  mkdir config
  cp ${
    host.config.environment.etc."home-assistant/configuration.yaml".source
  } config/configuration.yaml
  # Invoke the same upstream checker directly. The hass script dispatcher
  # tries pip-installing colorlog==6.10.1 even though nixpkgs ships 6.12.0;
  # no dependency downloads or validation suppression are needed here.
  ${py}/bin/python ${./check-config.py} "$PWD/config"
  mkdir "$out"
  cp matter-help.txt "$out/"
  printf '%s\n' 'Matter CLI imports/help and generated Home Assistant configuration check passed; no live pairing tested.' > "$out/result"
''
