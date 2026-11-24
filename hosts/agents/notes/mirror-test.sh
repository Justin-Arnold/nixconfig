#!/usr/bin/env bash
# Tests notes-mirror.sh against a bare repository standing in for forge.
#
# usage: mirror-test.sh <notes-mirror.sh>
set -uo pipefail

MIRROR=$1
TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP"; rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 HOME=$TMP XDG_CONFIG_HOME=$TMP/.config
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main

failed=0
check() { # description, then the command that must succeed
  local what=$1
  shift
  if "$@"; then echo "ok    $what"; else echo "FAIL  $what"; failed=1; fi
}

export VAULT=$TMP/vault MIRROR_URL=$TMP/forge.git
git init -q "$VAULT"
git init -q --bare "$MIRROR_URL"
# The forge accepts only fast-forwards of the vault's history.
git -C "$MIRROR_URL" config receive.denyNonFastForwards true
git -C "$MIRROR_URL" config receive.denyDeletes true

refs() { git -C "$1" for-each-ref --format='%(objectname) %(refname)'; }
same() { [[ $(refs "$VAULT") == "$(refs "$MIRROR_URL")" ]]; }
commit() { echo "$1" > "$VAULT/$1.md" && git -C "$VAULT" add -A && git -C "$VAULT" commit -qm "$1"; }

out=$(bash "$MIRROR" 2>&1)
check "a vault with no commits pushes nothing" test -z "$(refs "$MIRROR_URL")"
check "and says so" grep -q "no commits yet" <<<"$out"

commit one
commit two
git -C "$VAULT" branch -q side
check "the first push succeeds" bash "$MIRROR"
check "forge has every ref the vault has" same

# The vault read-only: the mirror never writes to it.
commit three
chmod -R a-w "$VAULT"
check "a read-only vault still pushes" bash "$MIRROR"
check "and forge has its new commit" same
chmod -R u+w "$VAULT"

# A hook in the vault never runs.
printf '#!/bin/sh\ntouch "%s/hook-ran"\n' "$TMP" > "$VAULT/.git/hooks/pre-push"
chmod +x "$VAULT/.git/hooks/pre-push"
commit four
check "a push with a pre-push hook in the vault succeeds" bash "$MIRROR"
check "the hook didn't run" test ! -e "$TMP/hook-ran"
rm "$VAULT/.git/hooks/pre-push"

# A commit lands while a push runs: a git on PATH that, the first time it
# pushes, commits once the push is done, as if notes.py had committed just
# then.
mkdir "$TMP/bin"
real_git=$(command -v git)
cat > "$TMP/bin/git" <<EOF
#!/bin/sh
case " \$* " in
  *" push "*)
    "$real_git" "\$@"
    status=\$?
    if [ ! -e "$TMP/committed" ]; then
      touch "$TMP/committed"
      echo late > "$VAULT/late.md"
      "$real_git" -C "$VAULT" add -A && "$real_git" -C "$VAULT" commit -qm late
    fi
    exit \$status ;;
esac
exec "$real_git" "\$@"
EOF
chmod +x "$TMP/bin/git"
commit five
check "a push during which a commit lands succeeds" env PATH="$TMP/bin:$PATH" bash "$MIRROR"
check "and forge has the late commit too" same
check "which is the vault's newest" test "$(git -C "$MIRROR_URL" log -1 --format=%s main)" = late

# A rewritten history is refused, and the mirror fails loudly.
git -C "$VAULT" commit -q --amend -m rewritten
check "a rewritten history fails the push" bash -c '! bash "$1" >/dev/null 2>&1' _ "$MIRROR"
check "and forge keeps what it had" test "$(git -C "$MIRROR_URL" log -1 --format=%s main)" = late

# The status agent-watch reads for MirrorStale.
export STATUS=$TMP/state/status.json
mkdir "$TMP/state"
# json <jq args>: whether the status matches, quietly.
json() { jq -e "$@" >/dev/null; }
back_to_forge() { git -C "$VAULT" reset -q --hard "$(git -C "$MIRROR_URL" rev-parse main)"; }
back_to_forge
check "a good push writes the status" bash "$MIRROR"
check "  ...which anyone can read, agent-watch included" test "$(stat -c %a "$STATUS")" = 644
check "  ...with the time it pushed and no error" \
  json '(.last_ok | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and .last_error == null' "$STATUS"
ok_before=$(jq -r .last_ok "$STATUS")
git -C "$VAULT" commit -q --amend -m rewritten-again
check "a refused push fails" bash -c '! bash "$1" >/dev/null 2>&1' _ "$MIRROR"
check "  ...and records git's reason and when, keeping last_ok" \
  json --arg ok "$ok_before" '.last_ok == $ok and (.last_error | test("non-fast-forward")) and .last_error_at != null' "$STATUS"
back_to_forge
echo 'not json' > "$STATUS"
check "a status that can't be read doesn't stop a push" bash "$MIRROR"
check "  ...and is written again" json '.last_ok != null' "$STATUS"
chmod a-w "$TMP/state"
commit six
check "a status that can't be written doesn't stop a push either" bash "$MIRROR"
check "  ...and forge still gets the commit" same
chmod u+w "$TMP/state"

exit $failed
