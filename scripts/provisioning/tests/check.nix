# nix build .#checks.<system>.provisioning
{ pkgs, manifest }:
pkgs.runCommand "provisioning-tests"
  {
    nativeBuildInputs = with pkgs; [ age bash coreutils diffutils findutils gnugrep gnused jq shellcheck ];
  }
  ''
    shellcheck ${../provision-host.sh} ${../inspect-cloud-host.sh} ${../../lab118/post-install-check.sh} ${../../lab118/send-test-alert.sh} ${../../lab118/check-lab-tunnel.sh} ${../../lab118/diagnose-lab-dns.sh}
    if ! bash ${./run.sh} ${../provision-host.sh} ${../plan-guard.jq} ${manifest} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
