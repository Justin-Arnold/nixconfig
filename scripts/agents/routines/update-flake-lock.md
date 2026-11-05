The weekly update of nixconfig's flake.lock, for {{date}}.

1. `agent-worktree Justin-Arnold/nixconfig flake-update-{{date}}`, and work in
   the folder it prints.
2. Run `nix flake update` and keep its output: it lists each input that
   moved.
3. If flake.lock didn't change, comment that every input was already current
   and set this issue to done. There's nothing to push.
4. Run `scripts/flake-check.sh eval`, with a 600-second timeout.
5. Commit only flake.lock, with the message "Update flake.lock ({{date}})",
   push the branch, and open a pull request to master with the same title.
   Its description lists each input that moved, with its old and new
   revision and date, and the summary lines of the eval. If the eval failed,
   open it as a draft and put the failure first.
6. Comment the pull request's link on this issue and set it to done.

Run `scripts/flake-check.sh checks` too only if the eval passed and more than
20 minutes of the run are left; say in the pull request whether you did.
Change no other file, and don't merge.
