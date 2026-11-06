#!/usr/bin/env bash
# Lands an agent's pull request as a commit of your own. GitHub's squash
# merge credits the pull request's author, the machine account, so this
# squashes the branch onto the base branch in a throwaway worktree, opens
# your editor for the message, pushes the result and closes the pull request
# with a pointer to the commit. Your checkout's branches and files aren't
# touched.
#
# It lands only a pull request whose checks have all passed. --skip-checks
# lands one anyway, and says so in the commit and on the pull request.
#
#   scripts/workbench/land-pr.sh [--skip-checks] <number>    (inside a checkout of the repo)
set -euo pipefail

skip_checks=false
if [[ ${1:-} == --skip-checks ]]; then
  skip_checks=true
  shift
fi
if [[ $# -ne 1 || ! $1 =~ ^[0-9]+$ ]]; then
  echo "usage: $0 [--skip-checks] <pull request number>" >&2
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

# Every check on the pull request's head has to have passed (or been
# skipped). gh exits non-zero while any is failing or pending, so its
# output is what counts.
checks=$(gh pr checks "$n" --json bucket,name --jq '.[] | "\(.bucket)\t\(.name)"' 2>/dev/null || true)
not_green=$(awk -F '\t' '$1 != "pass" && $1 != "skipping"' <<<"$checks")
if [[ -z $checks ]]; then
  not_green="none	no checks have run"
fi
skipped_note=""
if [[ -n $not_green ]]; then
  if [[ $skip_checks != true ]]; then
    echo "#$n isn't green:" >&2
    awk -F '\t' '{ printf "  %-8s %s\n", $1, $2 }' <<<"$not_green" >&2
    echo "Wait for its checks, or pass --skip-checks to land it anyway." >&2
    exit 1
  fi
  skipped_note="Landed with --skip-checks: $(awk -F '\t' '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, $1 }' <<<"$not_green")."
fi

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
  [[ -z $skipped_note ]] || printf '%s\n\n' "$skipped_note"
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
if ! gh pr close "$n" --delete-branch --comment "Landed as $landed.${skipped_note:+ $skipped_note}"; then
  echo "Landed as $landed, but #$n is still open; close it by hand." >&2
  exit 1
fi
echo "Landed #$n as ${landed:0:12} on $base."
