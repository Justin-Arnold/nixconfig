# nix build .#checks.<system>.provisioning
{ pkgs, manifest }:
pkgs.runCommand "provisioning-tests"
  {
    nativeBuildInputs = with pkgs; [ actionlint age bash coreutils diffutils findutils gnugrep gnused jq python3 shellcheck ];
  }
  ''
    shellcheck ${../provision-host.sh} ${../inspect-cloud-host.sh} ${../../lab118/post-install-check.sh} ${../../lab118/send-test-alert.sh} ${../../lab118/check-lab-tunnel.sh} ${../../lab118/diagnose-lab-dns.sh} ${../../dashboard/post-install-check.sh} ${../../automation/post-install-check.sh} ${../../dashboard/probe-mcp-block.sh} ${../../agents/post-install-check.sh} ${../../workbench/post-install-check.sh} ${../../workbench/land-pr.sh} ${../../openclaw/post-install-check.sh} ${../../inference/post-install-check.sh} ${../../flake-check.sh}
    python3 -c 'import ast, sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' ${../../dashboard/homarr-apply.py} ${../../agents/smoke-e2e.py}
    jq -e '.boards and .apps' ${../../dashboard/homarr-spec.json} >/dev/null
    jq -e '.company.issuePrefix and .labels and .agents' ${../../agents/paperclip-spec.json} >/dev/null
    if ! python3 -I ${../../agents/tests/paperclip-apply-test.py} ${../../agents/paperclip-apply.py} >paperclip.log 2>&1; then
      cat paperclip.log
      exit 1
    fi
    # The whole directory, since paperclip-cancel.py loads paperclip-apply.py from beside it.
    if ! python3 -I ${../../agents}/tests/paperclip-cancel-test.py ${../../agents}/paperclip-cancel.py >paperclip-cancel.log 2>&1; then
      cat paperclip-cancel.log
      exit 1
    fi
    # The same for paperclip-board-key.py, with a fake sops.
    if ! python3 -I ${../../agents}/tests/paperclip-board-key-test.py ${../../agents}/paperclip-board-key.py >paperclip-board-key.log 2>&1; then
      cat paperclip-board-key.log
      exit 1
    fi
    if ! python3 -I ${../../agents}/tests/paperclip-agent-key-test.py ${../../agents}/paperclip-agent-key.py >paperclip-agent-key.log 2>&1; then
      cat paperclip-agent-key.log
      exit 1
    fi
    if ! python3 -I ${../../inference/tests/model-test-test.py} ${../../inference/model-test.py} >model-test.log 2>&1; then
      cat model-test.log
      exit 1
    fi
    # n8n-apply.py against a fake n8n, then the real workflow files' checks.
    if ! python3 -I ${../../automation/tests/n8n-apply-test.py} ${../../automation/n8n-apply.py} ${../../../hosts/automation} >n8n-apply.log 2>&1; then
      cat n8n-apply.log
      exit 1
    fi
    python3 -I ${../../automation/n8n-apply.py} --check --host-dir ${../../../hosts/automation}
    if ! python3 -I ${../../ci/tests/lock-diff-test.py} ${../../ci/lock-diff.py} >lock-diff.log 2>&1; then
      cat lock-diff.log
      exit 1
    fi
    # The workflows, with shellcheck on their run steps.
    actionlint ${../../../.github/workflows}/*.yml
    jq -e '.bypass_actors == [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}] and .enforcement == "active"' \
      ${../../workbench/github-rulesets/branches.json} ${../../workbench/github-rulesets/tags.json} >/dev/null
    # GitHub matches with FNM_PATHNAME, so agent/** would leave out
    # agent/<agent>/<name>, the only kind of branch the agents make.
    jq -e '.conditions.ref_name == {include: ["~ALL"], exclude: ["refs/heads/agent/**/*"]}' \
      ${../../workbench/github-rulesets/branches.json} >/dev/null
    if ! bash ${./run.sh} ${../provision-host.sh} ${../plan-guard.jq} ${manifest} ${../proxmox-plan-guard.jq} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
