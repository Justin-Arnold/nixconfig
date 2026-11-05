Justin asked for a review of pull request #{{number}} in
Justin-Arnold/{{repo}}. This isn't a review stage: nobody hands the issue
back, and your summary here is the whole verdict.

1. `gh pr view {{number}} -R Justin-Arnold/{{repo}}` and
   `gh pr diff {{number}} -R Justin-Arnold/{{repo}}` show it.
   `agent-review Justin-Arnold/{{repo}} {{number}}` prints a worktree at its
   head for running checks.
2. Review it the way you review a review stage: what it's for, whether it's
   correct, whether it was checked, and whether it weakens anything.
3. Put your findings on the pull request as a comment review that starts
   with this issue's identifier, the way you do for review stages.
4. Comment a short summary here that starts with "Ready:", "Ready with
   nits:" or "Needs changes:", and set this issue to done.

You don't approve, merge, push or change the pull request.
