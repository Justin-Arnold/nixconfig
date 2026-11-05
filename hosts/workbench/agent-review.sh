# Usage: agent-review <owner/repo> <pr-number>
#
# Prints the path of a worktree at the head of pull request <pr-number>, for
# reading it and running its tests: ~/work/<repo>/pr-<n>, detached, so
# there's no branch to push. Running it again moves the worktree to the
# pull request's latest head, keeping untracked files such as build output.
# It refuses if tracked files were changed there. The repo is fetched into
# the same ~/repos/<owner>/<repo>.git as agent-worktree's.

if [[ $# -ne 2 || ! $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || $1 =~ (^|/)\.\.?(/|$)
  || ! $2 =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo "usage: agent-review <owner/repo> <pr-number>" >&2
  exit 2
fi

repo=$1
pr=$2
bare=$HOME/repos/$repo.git
tree=$HOME/work/${repo#*/}/pr-$pr

if [[ ! -d $bare ]]; then
  mkdir -p "$(dirname "$bare")"
  git init --quiet --bare "$bare"
  git -C "$bare" remote add origin "https://github.com/$repo.git"
fi
# Pull request heads live under refs/pull/<n>, where prune-worktrees looks.
git -C "$bare" fetch --quiet --prune origin \
  '+refs/heads/*:refs/remotes/origin/*' "+refs/pull/$pr/head:refs/pull/$pr"
head=$(git -C "$bare" rev-parse --verify "refs/pull/$pr^{commit}")

if [[ ! -d $tree ]]; then
  mkdir -p "$(dirname "$tree")"
  git -C "$bare" worktree add --quiet --detach "$tree" "$head"
elif [[ -n $(git -C "$tree" status --porcelain --untracked-files=no) ]]; then
  echo "agent-review: $tree has changed files, so it stays at $(git -C "$tree" rev-parse --short HEAD); undo them with git -C $tree checkout -- ." >&2
  exit 1
else
  git -C "$tree" checkout --quiet --detach "$head"
fi

echo "$tree"
