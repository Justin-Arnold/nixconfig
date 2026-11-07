# Usage: agent-worktree <owner/repo> <name>
#        agent-worktree <owner/repo> agent/<who>/<name>
#
# Prints the path of a git worktree for this agent's work called <name>, on
# the branch agent/<agent>/<name>. A new branch starts from the repo's
# default branch; one already on GitHub is picked up where it was. Running it
# again prints the same path. Each repo is fetched once per agent into
# ~/repos/<owner>/<repo>.git, and worktrees go in ~/work/<repo>/<name>.
#
# The second form picks up a branch that's already on GitHub under agent/,
# like agent/ci/flake-update-<date> from the weekly update, so the agent can
# push fixes onto that pull request. It goes in ~/work/<repo>/<who>-<name>,
# and this form never makes a branch.

usage() {
  echo "usage: agent-worktree <owner/repo> <name>  (name: lowercase letters, digits, '.', '_', '-')" >&2
  echo "       agent-worktree <owner/repo> agent/<who>/<name>  (a branch already on GitHub)" >&2
  exit 2
}

if [[ $# -ne 2 || ! $1 =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ || $1 =~ (^|/)\.\.?(/|$) ]]; then
  usage
fi

repo=$1
agent=$(id -un)
agent=${agent#agent-}
existing=false
if [[ $2 =~ ^agent/([a-z0-9-]+)/([a-z0-9][a-z0-9._-]*)$ ]]; then
  if [[ ${BASH_REMATCH[1]} == "$agent" ]]; then
    # Its own branch, the same worktree as the short form.
    name=${BASH_REMATCH[2]}
  else
    name=${BASH_REMATCH[1]}-${BASH_REMATCH[2]}
    existing=true
  fi
  branch=$2
elif [[ $2 =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  name=$2
  branch=agent/$agent/$name
else
  usage
fi
bare=$HOME/repos/$repo.git
tree=$HOME/work/${repo#*/}/$name

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
  elif [[ $existing == true ]]; then
    echo "agent-worktree: there's no $branch on GitHub" >&2
    exit 1
  else
    git -C "$bare" worktree add --quiet --no-track -b "$branch" "$tree" origin/HEAD
  fi
fi

echo "$tree"
