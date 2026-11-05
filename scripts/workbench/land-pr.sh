#!/usr/bin/env bash
# Lands an agent's pull request as a commit of your own. GitHub's squash
# merge credits the pull request's author, the machine account, so this
# squashes the branch onto the base branch in a throwaway worktree, opens
# your editor for the message, pushes the result and closes the pull request
# with a pointer to the commit. Your checkout's branches and files aren't
# touched.
#
#   scripts/workbench/land-pr.sh <number>    (inside a checkout of the repo)
set -euo pipefail

if [[ $# -ne 1 || ! $1 =~ ^[0-9]+$ ]]; then
  echo "usage: $0 <pull request number>" >&2
  exit 2
fi
n=$1

fields=$(gh pr view "$n" --json state,url,baseRefName,headRefName,headRefOid,author,title \
  --jq '[.state, .url, .baseRefName, .headRefName, .headRefOid, .author.login, .title] | @tsv')
IFS=$'\t' read -r state url base head_ref head_oid author title <<<"$fields"
if [[ $state != OPEN ]]; then
  echo "#$n is $state, so there's nothing to land." >&2
  exit 1
fi
# Fetch and push by URL, so it doesn't matter what the remotes are called.
repo=${url%/pull/*}.git

tmp=$(mktemp -d)
tree=$tmp/tree
cleanup() {
  git worktree remove --force "$tree" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

git fetch --quiet "$repo" "refs/heads/$base"
base_oid=$(git rev-parse FETCH_HEAD)
git fetch --quiet "$repo" "refs/pull/$n/head"
if [[ $(git rev-parse FETCH_HEAD) != "$head_oid" ]]; then
  echo "#$n's branch moved while this ran; look at it again, then rerun." >&2
  exit 1
fi

git worktree add --quiet --detach "$tree" "$base_oid"
if ! out=$(git -C "$tree" merge --squash "$head_oid" 2>&1); then
  grep CONFLICT <<<"$out" >&2 || echo "$out" >&2
  echo "#$n doesn't apply cleanly to $base; ask the agent to rebase it." >&2
  exit 1
fi
if git -C "$tree" diff --cached --quiet; then
  echo "#$n changes nothing on $base." >&2
  exit 1
fi

{
  printf '%s (#%s)\n\n' "$title" "$n"
  printf '# Landing %s\n# from %s by %s, onto %s.\n' "$url" "$head_ref" "$author" "$base"
  printf "# Lines starting with '#' are dropped, and an empty message stops here.\n#\n# Commits:\n"
  git log --reverse --format='#   %h %s' "$base_oid..$head_oid"
  printf '#\n# Changes:\n'
  git -C "$tree" diff --cached --stat | sed 's/^/# /'
} >"$tmp/message"

if ! git -C "$tree" commit --quiet --edit --file="$tmp/message" --cleanup=strip; then
  echo "Nothing was pushed." >&2
  exit 1
fi
git -C "$tree" log -1 --stat --format='%n%h  %an <%ae>%n%n%B'
read -r -p "Push this to $base and close #$n? [y/N] " answer
if [[ $answer != [yY] ]]; then
  echo "Nothing was pushed."
  exit 1
fi

git -C "$tree" push --quiet "$repo" "HEAD:refs/heads/$base"
landed=$(git -C "$tree" rev-parse HEAD)
if ! gh pr close "$n" --delete-branch --comment "Landed as $landed."; then
  echo "Landed as $landed, but #$n is still open; close it by hand." >&2
  exit 1
fi
echo "Landed #$n as ${landed:0:12} on $base."
