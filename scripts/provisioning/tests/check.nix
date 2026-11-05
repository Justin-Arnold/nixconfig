# nix build .#checks.<system>.provisioning
{ pkgs, manifest }:
pkgs.runCommand "provisioning-tests"
  {
    nativeBuildInputs = with pkgs; [ age bash coreutils diffutils findutils gnugrep gnused jq python3 shellcheck ];
  }
  ''
    shellcheck ${../provision-host.sh} ${../inspect-cloud-host.sh} ${../../lab118/post-install-check.sh} ${../../lab118/send-test-alert.sh} ${../../lab118/check-lab-tunnel.sh} ${../../lab118/diagnose-lab-dns.sh} ${../../dashboard/post-install-check.sh} ${../../dashboard/probe-mcp-block.sh}
    python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' ${../../dashboard/homarr-apply.py}
    jq -e '.boards and .apps' ${../../dashboard/homarr-spec.json} >/dev/null
    if ! bash ${./run.sh} ${../provision-host.sh} ${../plan-guard.jq} ${manifest} ${../proxmox-plan-guard.jq} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
