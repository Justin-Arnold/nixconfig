#!/usr/bin/env bash
# notes-mirror: pushes the vault's git history to forge, every ref as it is
# here (git push --mirror), so Justin can read who changed what from his
# desktop. notes-mirror.path starts it whenever a branch moves in the vault,
# and a timer starts it too, in case a start was missed.
#
# A commit that lands while a push runs doesn't start the unit again, so
# after each push the refs are read again and pushed again if they moved.
# The forge refuses anything but a fast-forward of the vault's branch, so a
# rewritten history here fails the push instead of replacing what's there.
#
# It only reads the vault; it never writes to it. It runs no hooks from the
# vault either: whatever can write there shouldn't run code next to the
# deploy key.
#
# Each run writes STATUS, the status.json agent-watch reads to raise
# MirrorStale: last_ok when forge has everything, last_error and
# last_error_at when a run fails. It holds times and git's first error
# line, never what was pushed. A status it can't read or write never stops a
# push.
#
# Environment: VAULT, MIRROR_URL, STATUS (optional), and GIT_SSH_COMMAND
# from the unit (with the deploy key and forge's pinned host key).
set -euo pipefail

: "${VAULT:?}" "${MIRROR_URL:?}"

# record <jq args and filter>: updates STATUS, with $now as the time.
record() {
  [[ -n ${STATUS:-} ]] || return 0
  local old tmp
  old=$(jq -c 'objects' "$STATUS" 2>/dev/null) || true
  [[ -n $old ]] || old='{}'
  tmp=$(mktemp "$STATUS.XXXXXX" 2>/dev/null) || return 0
  if jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$@" <<<"$old" >"$tmp" \
      && chmod 0644 "$tmp" && mv -f "$tmp" "$STATUS"; then
    return 0
  fi
  rm -f "$tmp"
}

# A run that fails records why: git's first error line, or the exit code.
reason=
on_exit() {
  local code=$?
  if (( code != 0 )); then
    record --arg error "${reason:-notes-mirror exited with code $code}" \
      '.last_error = $error | .last_error_at = $now'
  fi
  exit "$code"
}
trap on_exit EXIT

refs() { git -C "$VAULT" for-each-ref --format='%(objectname) %(refname)'; }

push() {
  local err
  if err=$(git -c core.hooksPath=/dev/null -C "$VAULT" push --no-verify --mirror --quiet "$MIRROR_URL" 2>&1); then
    [[ -z $err ]] || printf '%s\n' "$err" >&2
    return 0
  fi
  printf '%s\n' "$err" >&2
  reason=$(grep -vE 'failed to push some refs|^hint:' <<<"$err" \
    | grep -m1 -E '^ *(ssh|fatal|error|remote|!|Host key)' | sed -E 's/^ +//') || true
  reason=${reason:-the push to forge failed}
  return 1
}

if ! git -C "$VAULT" rev-parse -q --verify HEAD >/dev/null; then
  echo "notes-mirror: the vault has no commits yet; nothing to push"
  record '.last_ok = $now'
  exit 0
fi

for _ in 1 2 3 4 5; do
  before=$(refs)
  push
  if [[ $(refs) == "$before" ]]; then
    echo "notes-mirror: forge has $(git -C "$VAULT" rev-parse --short HEAD)"
    record '.last_ok = $now'
    exit 0
  fi
done
echo "notes-mirror: the vault kept moving during five pushes; the next commit or the timer pushes the rest"
record '.last_ok = $now'
