# .#checks.<system>.cglt-previews-preview-ctl: runs preview-ctl against the
# contract in preview-ctl.nix with a stand-in host.sh, on any machine.
{ pkgs }:
let
  previewCtl = pkgs.callPackage ./preview-ctl.nix {
    # Replaced with a directory in the build below.
    workRoot = "@WORK_ROOT@";
    tools = [ pkgs.bash pkgs.coreutils ];
    wrappers = "";
  };
in
pkgs.runCommand "cglt-previews-preview-ctl-check" { nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ]; } ''
  set -euo pipefail
  cp ${previewCtl}/bin/preview-ctl ./preview-ctl
  chmod u+w ./preview-ctl
  mkdir work
  substituteInPlace ./preview-ctl --replace-fail "@WORK_ROOT@" "$PWD/work"

  mkdir -p job/previews/scripts other/previews
  cat >job/previews/scripts/host.sh <<'EOF'
  printf 'arg:%s\n' "$@"
  [[ $PWD == */work/job.* ]] && echo "in-job-dir"
  echo "PREVIEW_TAG=''${PREVIEW_TAG:-unset}"
  echo "OTHER=''${OTHER:-unset}"
  echo "SSH_AUTH_SOCK=''${SSH_AUTH_SOCK:-unset}"
  echo "HOME=$HOME USER=$USER"
  echo "PATH=$PATH"
  echo "umask=$(umask)"
  echo "to stderr" >&2
  exit 7
  EOF
  echo x >other/previews/README
  tar -czf job.tgz -C job previews
  tar -czf other.tgz -C other previews

  run() { # <expected status> <stdin> <command>
    local want=$1 input=$2 got=0
    SSH_ORIGINAL_COMMAND=$3 PREVIEW_TAG=satchel-cps OTHER=leak SSH_AUTH_SOCK=/tmp/agent.sock \
      HOME=/home/deploy USER=deploy ./preview-ctl <"$input" >out 2>err || got=$?
    if [[ $got != "$want" ]]; then
      echo "FAIL: '$3' exited $got, expected $want"; cat out err; exit 1
    fi
    if [[ -n $(ls -A work) ]]; then
      echo "FAIL: '$3' left $(ls -A work) in the work directory"; exit 1
    fi
  }

  run 7 job.tgz 'deploy satchel-cps pr=12 ref=feature/x@sha:1+2'
  grep -qx 'arg:deploy' out
  grep -qx 'arg:satchel-cps' out
  grep -qx 'arg:pr=12' out
  grep -qx 'arg:ref=feature/x@sha:1+2' out
  [[ $(grep -c '^arg:' out) == 4 ]]
  grep -qx 'in-job-dir' out
  grep -qx 'PREVIEW_TAG=satchel-cps' out
  grep -qx 'OTHER=unset' out
  grep -qx 'SSH_AUTH_SOCK=/tmp/agent.sock' out
  grep -qx 'HOME=/home/deploy USER=deploy' out
  grep -qx "PATH=${pkgs.bash}/bin:${pkgs.coreutils}/bin" out
  grep -qx 'umask=0022' out
  grep -qx 'to stderr' err

  run 2 job.tgz ""
  run 2 job.tgz "   "
  run 2 job.tgz 'deploy $(id)'
  run 2 job.tgz 'deploy a;b'
  run 2 job.tgz 'deploy *'
  run 2 job.tgz 'deploy ../x|y'
  run 2 job.tgz "$(printf 'deploy\nrm')"
  grep -q 'single line' err
  run 2 /dev/null 'list'
  grep -q "gzip'd tar" err
  run 2 other.tgz 'list'
  grep -q 'host.sh' err

  touch $out
''
