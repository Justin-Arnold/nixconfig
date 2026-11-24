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
# Environment: VAULT, MIRROR_URL, and GIT_SSH_COMMAND from the unit (with the
# deploy key and forge's pinned host key).
set -euo pipefail

: "${VAULT:?}" "${MIRROR_URL:?}"

refs() { git -C "$VAULT" for-each-ref --format='%(objectname) %(refname)'; }

if ! git -C "$VAULT" rev-parse -q --verify HEAD >/dev/null; then
  echo "notes-mirror: the vault has no commits yet; nothing to push"
  exit 0
fi

for _ in 1 2 3 4 5; do
  before=$(refs)
  git -c core.hooksPath=/dev/null -C "$VAULT" push --no-verify --mirror --quiet "$MIRROR_URL"
  if [[ $(refs) == "$before" ]]; then
    echo "notes-mirror: forge has $(git -C "$VAULT" rev-parse --short HEAD)"
    exit 0
  fi
done
echo "notes-mirror: the vault kept moving during five pushes; the next commit or the timer pushes the rest"
