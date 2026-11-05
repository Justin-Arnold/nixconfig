# Behavioural tests for doppler-secrets-sync. Runs anywhere bash/jq/age exist
# (the flake check runs it on macOS and Linux). doppler, systemctl and chown
# are replaced by fakes that record their calls.
#
# usage: test.sh <doppler-secrets-sync binary> <base spec json>
set -euo pipefail

SYNC="$1"
BASE_SPEC="$2"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0
fail=0
check() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS  $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name"
    fail=$((fail + 1))
  fi
}

mkdir -p "$T/bin" "$T/fake"
age-keygen -o "$T/host.key" 2>/dev/null
age-keygen -o "$T/operator.key" 2>/dev/null
operator_pub="$(age-keygen -y "$T/operator.key")"
jq --arg r "$operator_pub" '.recipients = [$r]' "$BASE_SPEC" >"$T/spec.json"
printf 'dp.st.prd.FAKETOKEN0123456789\n' >"$T/token"

cat >"$T/bin/doppler" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/doppler.calls"
if [[ "${DOPPLER_TOKEN:-}" != "dp.st.prd.FAKETOKEN0123456789" ]]; then
  echo "Doppler Error: invalid token" >&2
  exit 9
fi
case "$(cat "$FAKE/mode")" in
  ok) cat "$FAKE/doppler.json" ;;
  *) echo "Doppler Error: Unable to reach api.doppler.com using dp.st.prd.FAKETOKEN0123456789" >&2; exit 1 ;;
esac
EOF
cat >"$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/systemctl.calls"
EOF
cat >"$T/bin/chown" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/chown.calls"
EOF
chmod +x "$T/bin/"*

export FAKE="$T/fake"
export DOPPLER_BIN="$T/bin/doppler" SYSTEMCTL_BIN="$T/bin/systemctl" CHOWN_BIN="$T/bin/chown"
export DOPPLER_SECRETS_SPEC="$T/spec.json"
export DOPPLER_SECRETS_RUNTIME_DIR="$T/run"
export DOPPLER_SECRETS_STATE_DIR="$T/state"
export DOPPLER_SECRETS_AGE_IDENTITY="$T/host.key"
export DOPPLER_SECRETS_TOKEN_FILE="$T/token"
export DOPPLER_SECRETS_FETCH_RETRY_SECONDS=0

# Every secret value contains S3CR3T so leaks are easy to detect.
cat >"$T/secrets.json" <<'EOF'
{
  "ALERTA_SECRET_KEY": "S3CR3T-flask-key",
  "ALERTA_ADMIN_USER": "S3CR3T-admin",
  "ALERTA_ADMIN_PASSWORD": "S3CR3T-admin-password",
  "ALERTA_API_KEY": "S3CR3T-api-key",
  "APPRISE_CONFIG": "ntfy://apprise:S3CR3T-pw@notifications.host.internal:8080/homelab-alerts\nmailto://u:S3CR3T-mail@example.com",
  "NTFY_AUTH_USERS": "justin:$2a$10$S3CR3Thash:admin,apprise:$2a$10$S3CR3Thash2:user",
  "NTFY_AUTH_TOKENS": "apprise:tk_S3CR3Ttoken:apprise",
  "NEWT_ID": "S3CR3Tnewtid",
  "NEWT_SECRET": "S3CR3Tnewtsecret",
  "DOPPLER_PROJECT": "lab118-services",
  "DOPPLER_CONFIG": "prd",
  "DOPPLER_ENVIRONMENT": "prd"
}
EOF

serve() { cp "$1" "$FAKE/doppler.json"; echo ok >"$FAKE/mode"; }
doppler_down() { echo down >"$FAKE/mode"; }
reset_calls() { : >"$FAKE/doppler.calls"; : >"$FAKE/systemctl.calls"; : >"$FAKE/chown.calls"; }
run_sync() {
  RC=0
  "$SYNC" "$1" >"$T/last.log" 2>&1 || RC=$?
  cat "$T/last.log" >>"$T/all.log"
}
with_secret() { jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$T/secrets.json" >"$T/variant.json"; echo "$T/variant.json"; }
without_secret() { jq --arg k "$1" 'del(.[$k])' "$T/secrets.json" >"$T/variant.json"; echo "$T/variant.json"; }
snapshot() { (cd "$T/run" && find . -type f ! -path './.work*' -exec sha256sum {} + | sort) >"$1"; sha256sum "$T/state/cache.json.age" >>"$1" 2>/dev/null || true; }
expect_rc() { [[ "$RC" == "$1" ]]; }
no_calls() { [[ ! -s "$FAKE/$1.calls" ]]; }
same_as() { snapshot "$T/now.snap"; cmp -s "$1" "$T/now.snap"; }
log_has() { grep -qF -- "$1" "$T/last.log"; }
raw_value() { jq -j --arg k "$1" '.[$k]' "$T/secrets.json"; }
file_is() { [[ "$(cat "$T/run/$1")" == "$2" ]]; }
mode_is() { [[ "$(stat -c %a "$T/run/$1")" == "$2" ]]; }
cache_keys_are_required() {
  [[ "$(age -d -i "$T/operator.key" "$T/state/cache.json.age" | jq -c 'keys')" == "$(jq -c '.requiredKeys | sort' "$T/spec.json")" ]]
}

echo "== first boot: no cache, Doppler reachable"
serve "$T/secrets.json"; reset_calls; run_sync ensure
check "ensure exits 0" expect_rc 0
check "raw file is byte-exact" file_is alerta/secret-key "$(raw_value ALERTA_SECRET_KEY)"
check "multi-line raw file is byte-exact" cmp -s "$T/run/apprise/homelab-alerts.cfg" <(raw_value APPRISE_CONFIG)
check "systemd-env file has quoted values and static vars" file_is ntfy.env "$(printf "%s\n" \
  "NTFY_AUTH_TOKENS='$(raw_value NTFY_AUTH_TOKENS)'" \
  "NTFY_AUTH_USERS='$(raw_value NTFY_AUTH_USERS)'" \
  "NTFY_AUTH_ACCESS='apprise:homelab-alerts:write-only'")"
check "docker-env file is unquoted" file_is node-red.env "ALERTA_API_KEY=$(raw_value ALERTA_API_KEY)"
check "files are mode 0400" mode_is alerta/secret-key 400
check "runtime dirs are 0751" [ "$(stat -c %a "$T/run/alerta")" = 751 ]
check "ownership applied (alerta:alerta)" grep -qx "alerta:alerta $T/run/alerta/.secret-key.new" "$FAKE/chown.calls"
check "no service restarts at boot" no_calls systemctl
check "cache written" [ -s "$T/state/cache.json.age" ]
check "operator key can decrypt cache; cache holds only required keys" cache_keys_are_required
snapshot "$T/boot.snap"

echo "== reboot while Doppler is down"
rm -rf "$T/run"; doppler_down; reset_calls; run_sync ensure
check "ensure exits 0 from cache" expect_rc 0
check "Doppler not contacted when a cache exists" no_calls doppler
check "rendered files identical to before" same_as "$T/boot.snap"

echo "== ensure again (unit restarted, nothing to do)"
reset_calls; run_sync ensure
check "ensure exits 0" expect_rc 0
check "no Doppler call, no restarts" bash -c '[ ! -s "$FAKE/doppler.calls" ] && [ ! -s "$FAKE/systemctl.calls" ]'

echo "== refresh with unchanged Doppler content"
serve "$T/secrets.json"; reset_calls; run_sync refresh
check "refresh exits 0" expect_rc 0
check "no restarts" no_calls systemctl
check "files and cache unchanged" same_as "$T/boot.snap"

echo "== refresh with one changed key"
serve "$(with_secret NTFY_AUTH_TOKENS 'apprise:tk_S3CR3Tnewtoken:apprise')"; reset_calls; run_sync refresh
check "refresh exits 0" expect_rc 0
check "only ntfy-sh restarted" [ "$(cat "$FAKE/systemctl.calls")" = "try-restart ntfy-sh.service" ]
check "ntfy.env updated" grep -qF "tk_S3CR3Tnewtoken" "$T/run/ntfy.env"
check "unrelated file untouched" cmp -s "$T/run/alerta/secret-key" <(raw_value ALERTA_SECRET_KEY)
snapshot "$T/changed.snap"

echo "== refresh while Doppler is down"
doppler_down; reset_calls; run_sync refresh
check "refresh exits 2" expect_rc 2
check "no restarts" no_calls systemctl
check "files and cache unchanged" same_as "$T/changed.snap"
check "token redacted in log" bash -c 'grep -q "dp.<redacted>" "$0" && ! grep -q FAKETOKEN "$0"' "$T/last.log"

rejects() { # name, expected message, then the command that builds the variant
  local name="$1" message="$2"
  shift 2
  "$@" >/dev/null
  echo "== refresh rejects: $name"
  serve "$T/variant.json"; reset_calls; run_sync refresh
  check "exits 3" expect_rc 3
  check "names the problem" log_has "$message"
  check "no restarts" no_calls systemctl
  check "files and cache unchanged" same_as "$T/changed.snap"
}
rejects "missing key" "NEWT_SECRET: missing" without_secret NEWT_SECRET
rejects "empty value" "ALERTA_API_KEY: empty" with_secret ALERTA_API_KEY ""
rejects "line break in env value" "NTFY_AUTH_USERS: contains a line break" with_secret NTFY_AUTH_USERS $'justin:S3CR3T:admin\nEVIL=1'
rejects "quote in systemd-env value" "NEWT_ID: contains a single quote" with_secret NEWT_ID "S3CR3T'id"
rejects "validator mismatch" "APPRISE_CONFIG: does not match" with_secret APPRISE_CONFIG "S3CR3T-not-a-url"
echo '{"truncated": ' >"$T/variant.json"
echo "== refresh rejects: malformed JSON"
serve "$T/variant.json"; reset_calls; run_sync refresh
check "exits 3" expect_rc 3
check "files and cache unchanged" same_as "$T/changed.snap"

echo "== corrupt cache with Doppler reachable"
echo garbage >"$T/state/cache.json.age"; rm -rf "$T/run"; serve "$T/secrets.json"; reset_calls; run_sync ensure
check "ensure exits 0 by refetching" expect_rc 0
check "cache valid again" cache_keys_are_required

echo "== first boot with no cache and Doppler down, then Doppler recovers"
rm -rf "$T/run" "$T/state"; doppler_down; reset_calls; run_sync ensure
check "ensure exits 4" expect_rc 4
check "no runtime files" [ ! -e "$T/run/ntfy.env" ]
serve "$T/secrets.json"; reset_calls; run_sync refresh
check "refresh exits 0" expect_rc 0
check "all mapped services (re)started" [ "$(sort "$FAKE/systemctl.calls" | tr '\n' ' ')" = "restart alerta-bootstrap.service restart alerta.service restart docker-apprise.service restart docker-node-red.service restart newt.service restart ntfy-sh.service " ]

echo "== no secret values or tokens in any output"
check "no S3CR3T in logs" bash -c '! grep -q S3CR3T "$0"' "$T/all.log"
check "no token in logs" bash -c '! grep -q FAKETOKEN "$0"' "$T/all.log"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
