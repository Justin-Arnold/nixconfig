CI is red on pull request #{{number}} in Justin-Arnold/{{repo}}. Make it
green. n8n started this when check.yml finished red on the pull request's
branch, which is under `agent/`, so you can push to it: usually the weekly
flake update's `agent/ci/flake-update-<date>`, or one of yours. When you
push, CI runs again and its result comes back the same way: green tells
Justin it's ready to land, and red starts this again.

1. `gh pr view {{number}} -R Justin-Arnold/{{repo}} --json headRefName,body`
   gives the branch. `agent-worktree Justin-Arnold/{{repo}} <branch>` prints a
   worktree on it; work there.
2. Read what failed: `gh pr checks {{number}} -R Justin-Arnold/{{repo}}`, then
   `gh run view <run id> -R Justin-Arnold/{{repo}} --log-failed` for each
   failed job. A job's name says what to re-run: `eval NixOS hosts`, `eval
   darwin hosts`, or a check's name.
3. Reproduce only what failed: `scripts/flake-check.sh eval <hosts>` or
   `scripts/flake-check.sh checks <checks>`. They take minutes, so start
   each as a background command and wait with `process_manage wait`. The
   darwin hosts can't be evaluated on workbench: work from their log.
4. Fix it, one commit per cause, and re-run what failed after each.
   - On your own you may fix:
     - an option or package that was renamed or removed, where nixpkgs or the
       release notes name the replacement and it behaves the same (journald's
       `extraConfig` became `settings.Journal`);
     - an API change in our own code, once its test passes (FastMCP became
       MCPServer);
     - a new upstream default that trips a guard, by setting the old
       behaviour back (podman opening DNS on its bridges).
   - Ask Justin first when there's more than one reasonable answer:
     replacing a program with another (hyprpanel), marking a host legacy, or
     anything that changes how a service or his desktop behaves (pnpm 10 no
     longer runs install scripts).
   - Never weaken a guard, an assertion or a deny list, touch a secret,
     merge, or deploy.
   - A fix that touches a firewall, exposure, authentication or egress gets
     the `sensitive` label on this issue and a "Sensitive changes" section in
     the pull request.
5. Research from source, not memory: the error's own text, the release
   notes under `nixos/doc/manual/release-notes` in nixpkgs, `pkgs/by-name`
   and the package's `meta`, Home Manager's `modules/`, and upstream READMEs
   with `gh api repos/<owner>/<repo>/readme`. Say what you read.
6. If you need Justin, push what you have and ask him the way your soul
   says. His answer wakes you here.
7. Push to the same branch. Then edit the pull request's description: keep
   what's there and add a "Fixes" section with each fix and its cause, each
   question you asked and his answer, and the hosts to switch, in order,
   agents first. Comment on the pull request what you changed.
8. Comment the pull request's link and what you fixed here, and set this
   issue to done. Don't wait for CI: its result comes back on its own.

If the failure isn't in the repo at all, like a runner that died or a
download that timed out, say so here, ask Justin whether to re-run it, and
change nothing.
