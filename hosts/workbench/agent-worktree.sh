# Usage: agent-worktree <owner/repo> <name>
#
# Prints the path of a git worktree for this agent's work called <name>, on
# the branch agent/<agent>/<name>. A new branch starts from the repo's
# default branch; one already on GitHub is picked up where it was. Running it
# again prints the same path. Each repo is fetched once per agent into
# ~/repos/<owner>/<repo>.git, and worktrees go in ~/work/<repo>/<name>.

if [[ $# -ne 2 || ! $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || $1 =~ (^|/)\.\.?(/|$)
  || ! $2 =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  echo "usage: agent-worktree <owner/repo> <name>  (name: lowercase letters, digits, '.', '_', '-')" >&2
  exit 2
fi

repo=$1
name=$2
agent=$(id -un)
agent=${agent#agent-}
bare=$HOME/repos/$repo.git
tree=$HOME/work/${repo#*/}/$name
branch=agent/$agent/$name

if [[ ! -d $bare ]]; then
  mkdir -p "$(dirname "$bare")"
  git init --quiet --bare "$bare"
  git -C "$bare" remote add origin "https://github.com/$repo.git"
fi
git -C "$bare" fetch --quiet --prune origin
git -C "$bare" remote set-head origin --auto >/dev/null

if [[ ! -d $tree ]]; then
  mkdir -p "$(dirname "$tree")"
  if git -C "$bare" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$bare" worktree add --quiet "$tree" "$branch"
  elif git -C "$bare" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    git -C "$bare" worktree add --quiet --track -b "$branch" "$tree" "origin/$branch"
  else
    git -C "$bare" worktree add --quiet --no-track -b "$branch" "$tree" origin/HEAD
  fi
fi

echo "$tree"
