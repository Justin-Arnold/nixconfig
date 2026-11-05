# Usage: prune-worktrees <home> <days>
#
# Run as the agent. Removes the agent's worktrees that nobody touched for
# <days> days, with their local branches, but only when nothing in them
# would be lost: no uncommitted or untracked files, and no commits that
# aren't on GitHub. The rest are listed and left alone. GitHub keeps every
# pull request's commits under refs/pull/<n>/head after its branch is
# deleted, so those count as on GitHub, and a landed branch goes too.

home=$1
days=$2
shopt -s nullglob

for bare in "$home"/repos/*/*.git; do
  git -C "$bare" worktree prune
  # Pull request heads go under refs/pull, apart from the branches, so
  # pruning one set never removes the other.
  if ! git -C "$bare" fetch --quiet --prune origin \
      '+refs/heads/*:refs/remotes/origin/*' '+refs/pull/*/head:refs/pull/*'; then
    echo "skipping $bare: fetch failed, so what's on GitHub is unknown"
    continue
  fi
  git -C "$bare" worktree list --porcelain | sed -n 's/^worktree //p' | { grep -vxF "$bare" || true; } \
    | while read -r tree; do
        if [[ -n $(find "$tree" -name .git -prune -o -newermt "$days days ago" -print -quit) ]]; then
          continue
        fi
        branch=$(git -C "$tree" symbolic-ref --quiet --short HEAD || true)
        if [[ -n $(git -C "$tree" status --porcelain) ]]; then
          echo "keeping $tree: uncommitted changes"
        elif [[ -n $branch && -n $(git -C "$tree" rev-list "$branch" --not --remotes=origin --glob='refs/pull/*') ]]; then
          echo "keeping $tree: commits that aren't on GitHub"
        else
          git -C "$bare" worktree remove "$tree"
          if [[ -n $branch ]]; then
            git -C "$bare" branch --quiet -D "$branch"
          fi
          echo "removed $tree"
        fi
      done
done
