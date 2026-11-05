# doppler-secrets-sync: materialize Doppler secrets into runtime files, backed by
# a validated, age-encrypted last-known-good cache.
#
#   ensure   Boot/switch path. Make the runtime files match the cache and the
#            current spec. Doppler is contacted only when no usable cache
#            exists (first boot), so a Doppler outage cannot block restarts.
#   refresh  Fetch from Doppler and validate the complete set. Only then
#            replace the cache, atomically swap changed files, and try-restart
#            only the services whose files changed. On any failure nothing
#            changes.
#
# Never prints secret values; messages name keys and paths only.
#
# Exit codes: 0 ok, 1 usage, 2 Doppler unavailable, 3 fetched set invalid,
#             4 no usable cache and Doppler unavailable, 5 a restart failed.
set -euo pipefail
umask 077

: "${DOPPLER_SECRETS_SPEC:?spec file}"
: "${DOPPLER_SECRETS_RUNTIME_DIR:?runtime dir}"
: "${DOPPLER_SECRETS_STATE_DIR:?state dir}"
: "${DOPPLER_SECRETS_AGE_IDENTITY:?age identity file}"
: "${DOPPLER_SECRETS_TOKEN_FILE:?Doppler service token file}"
DOPPLER_BIN="${DOPPLER_BIN:-doppler}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
CHOWN_BIN="${CHOWN_BIN:-chown}"
FETCH_ATTEMPTS="${DOPPLER_SECRETS_FETCH_ATTEMPTS:-1}"
FETCH_RETRY_SECONDS="${DOPPLER_SECRETS_FETCH_RETRY_SECONDS:-10}"
FETCH_TIMEOUT_SECONDS="${DOPPLER_SECRETS_FETCH_TIMEOUT_SECONDS:-60}"

mode="${1:-}"
spec="$DOPPLER_SECRETS_SPEC"
run="$DOPPLER_SECRETS_RUNTIME_DIR"
state="$DOPPLER_SECRETS_STATE_DIR"
cache="$state/cache.json.age"
complete="$run/.complete"

log() { printf 'doppler-secrets: %s\n' "$*" >&2; }
redact() { sed -E 's/dp\.[a-z]+\.[A-Za-z0-9._-]+/dp.<redacted>/g'; }

case "$mode" in
  ensure|refresh) ;;
  *) echo "usage: doppler-secrets-sync ensure|refresh" >&2; exit 1 ;;
esac

install -d -m 0700 "$state"
install -d -m 0751 "$run"
work="$(mktemp -d "$run/.work.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Serialize boot, refresh and manual runs.
exec 9>"$state/lock"
flock 9

spec_hash="$(sha256sum "$spec" | cut -d' ' -f1)"
output_count="$(jq '.outputs | length' "$spec")"

cat >"$work/validate.jq" <<'JQ'
. as $s
| $spec[0] as $spec
| if type != "object" then ["response is not a JSON object"] else
    [ $spec.requiredKeys[] as $k
      | if ($s | has($k) | not) then "\($k): missing"
        elif ($s[$k] | type) != "string" then "\($k): not a string"
        elif ($s[$k] | length) == 0 then "\($k): empty"
        else empty end ]
    + [ $spec.outputs[] | select(.format != "raw") as $o
        | $o.vars | to_entries[] | .value as $k
        | select(($s | has($k)) and (($s[$k] | type) == "string"))
        | if ($s[$k] | test("[\r\n]")) then "\($k): contains a line break (not allowed in \($o.format) file \($o.path))"
          elif ($o.format == "systemd-env" and ($s[$k] | test("'"))) then "\($k): contains a single quote (not allowed in \($o.format) file \($o.path))"
          else empty end ]
    + [ $spec.validators | to_entries[] | .key as $k | .value as $re
        | select(($s | has($k)) and (($s[$k] | type) == "string"))
        | select($s[$k] | test($re) | not)
        | "\($k): does not match the expected format" ]
  end
| unique | .[]
JQ

cat >"$work/subset.jq" <<'JQ'
. as $s | $spec[0].requiredKeys | map({ key: ., value: $s[.] }) | from_entries
JQ

cat >"$work/render.jq" <<'JQ'
. as $s
| $spec[0].outputs[$i] as $o
| if $o.format == "raw" then $s[$o.key]
  elif $o.format == "systemd-env" then
    ([ $o.vars | to_entries[] | "\(.key)='\($s[.value])'" ]
     + [ $o.static | to_entries[] | "\(.key)='\(.value)'" ]) | map(. + "\n") | join("")
  else
    ([ $o.vars | to_entries[] | "\(.key)=\($s[.value])" ]
     + [ $o.static | to_entries[] | "\(.key)=\(.value)" ]) | map(. + "\n") | join("")
  end
JQ

# Prints validation problems (key names only); returns 1 if any.
validate() {
  local problems
  if ! problems="$(jq -r --slurpfile spec "$spec" -f "$work/validate.jq" "$1" 2>/dev/null)"; then
    log "invalid: response is not valid JSON"
    return 1
  fi
  if [[ -n "$problems" ]]; then
    while IFS= read -r p; do log "invalid: $p"; done <<<"$problems"
    return 1
  fi
}

canonical_subset() { jq -S -c --slurpfile spec "$spec" -f "$work/subset.jq" "$1" >"$2" 2>/dev/null; }

fetch() {
  local out="$1" err="$work/doppler.err" attempt=1 rc token
  if [[ ! -r "$DOPPLER_SECRETS_TOKEN_FILE" ]]; then
    log "Doppler token file is missing: $DOPPLER_SECRETS_TOKEN_FILE"
    return 2
  fi
  token="$(<"$DOPPLER_SECRETS_TOKEN_FILE")"
  while :; do
    rc=0
    DOPPLER_TOKEN="$token" \
      DOPPLER_CONFIG_DIR="$state/cli" \
      DOPPLER_ENABLE_VERSION_CHECK=false \
      timeout "$FETCH_TIMEOUT_SECONDS" "$DOPPLER_BIN" secrets download \
        --no-file --format json --no-fallback --no-check-version \
        >"$out" 2>"$err" || rc=$?
    if [[ $rc -eq 0 ]]; then
      return 0
    fi
    log "Doppler fetch failed (attempt $attempt/$FETCH_ATTEMPTS, exit $rc): $(redact <"$err" | tr '\n' ' ' | cut -c1-300)"
    if (( attempt >= FETCH_ATTEMPTS )); then
      return 2
    fi
    attempt=$((attempt + 1))
    sleep "$FETCH_RETRY_SECONDS"
  done
}

decrypt_cache() {
  [[ -f "$cache" ]] || return 1
  age -d -i "$DOPPLER_SECRETS_AGE_IDENTITY" -o "$1" "$cache" 2>/dev/null
}

write_cache() {
  local args=() r
  while IFS= read -r r; do
    [[ -n "$r" ]] && args+=(-r "$r")
  done < <(age-keygen -y "$DOPPLER_SECRETS_AGE_IDENTITY"; jq -r '.recipients[]' "$spec")
  age -e "${args[@]}" -o "$cache.new" "$1"
  chmod 0600 "$cache.new"
  mv -f "$cache.new" "$cache"
}

# Render every output from a canonical secrets file and install the ones that
# differ. Appends services of changed outputs to the global `changed_services`.
changed_services=()
install_outputs() {
  local src="$1" i path format owner group fmode target dir staged tmp
  install -d -m 0700 "$work/out"
  for ((i = 0; i < output_count; i++)); do
    path="$(jq -r ".outputs[$i].path" "$spec")"
    format="$(jq -r ".outputs[$i].format" "$spec")"
    owner="$(jq -r ".outputs[$i].owner" "$spec")"
    group="$(jq -r ".outputs[$i].group" "$spec")"
    fmode="$(jq -r ".outputs[$i].mode" "$spec")"
    staged="$work/out/$i"
    jq -j --slurpfile spec "$spec" --argjson i "$i" -f "$work/render.jq" "$src" >"$staged" 2>/dev/null

    target="$run/$path"
    dir="$(dirname "$target")"
    install -d -m 0751 "$dir"
    if [[ -f "$target" ]] && cmp -s "$staged" "$target"; then
      chmod "$fmode" "$target"
      "$CHOWN_BIN" "$owner:$group" "$target"
      continue
    fi
    tmp="$dir/.$(basename "$target").new"
    cp "$staged" "$tmp"
    chmod "$fmode" "$tmp"
    "$CHOWN_BIN" "$owner:$group" "$tmp"
    mv -f "$tmp" "$target"
    log "updated $path ($format)"
    while IFS= read -r svc; do
      [[ -n "$svc" ]] && changed_services+=("$svc")
    done < <(jq -r ".outputs[$i].restart[]" "$spec")
  done
}

all_services() { jq -r '[.outputs[].restart[]] | unique | .[]' "$spec"; }

restart_services() { # verb, services...
  local verb="$1" svc failed=0
  shift
  for svc in $(printf '%s\n' "$@" | sort -u); do
    log "$verb $svc.service"
    "$SYSTEMCTL_BIN" "$verb" "$svc.service" || { log "failed to $verb $svc.service"; failed=1; }
  done
  return "$failed"
}

runtime_current() {
  [[ -f "$complete" && "$(cat "$complete")" == "$spec_hash" ]] || return 1
  local i
  for ((i = 0; i < output_count; i++)); do
    [[ -f "$run/$(jq -r ".outputs[$i].path" "$spec")" ]] || return 1
  done
}

ensure() {
  local was_complete=0
  [[ -f "$complete" ]] && was_complete=1
  if runtime_current; then
    log "runtime secrets already current"
    return 0
  fi

  if decrypt_cache "$work/cached.json" && validate "$work/cached.json"; then
    canonical_subset "$work/cached.json" "$work/current.json"
    install_outputs "$work/current.json"
    printf '%s' "$spec_hash" >"$complete"
    log "rendered from last-known-good cache (Doppler not contacted)"
  else
    [[ -f "$cache" ]] && log "cache is unusable for the current spec; trying Doppler"
    if ! fetch "$work/fetched.json"; then
      log "no usable cache and Doppler is unavailable"
      return 4
    fi
    if ! validate "$work/fetched.json"; then
      log "refusing to install an invalid secret set"
      return 3
    fi
    canonical_subset "$work/fetched.json" "$work/current.json"
    write_cache "$work/current.json"
    install_outputs "$work/current.json"
    printf '%s' "$spec_hash" >"$complete"
    log "seeded cache from Doppler"
  fi

  # At boot the runtime dir is empty and services start after this unit.
  # When re-run by a switch, restart whatever changed.
  if (( was_complete )) && (( ${#changed_services[@]} )); then
    restart_services try-restart "${changed_services[@]}" || return 5
  fi
}

refresh() {
  local was_current=0
  runtime_current && was_current=1

  if ! fetch "$work/fetched.json"; then
    log "keeping last-known-good secrets"
    return 2
  fi
  if ! validate "$work/fetched.json"; then
    log "refusing update; keeping last-known-good secrets"
    return 3
  fi
  canonical_subset "$work/fetched.json" "$work/new.json"

  if decrypt_cache "$work/cached.json" \
    && canonical_subset "$work/cached.json" "$work/old.json" \
    && cmp -s "$work/new.json" "$work/old.json"; then
    log "no changes in Doppler"
  else
    write_cache "$work/new.json"
    log "cache updated"
  fi

  install_outputs "$work/new.json"
  printf '%s' "$spec_hash" >"$complete"

  if (( was_current )); then
    if (( ${#changed_services[@]} )); then
      restart_services try-restart "${changed_services[@]}" || return 5
    fi
  else
    # Runtime secrets were missing or stale (e.g. first boot during a Doppler
    # outage), so dependent services may have failed. Start them now.
    mapfile -t svcs < <(all_services)
    if (( ${#svcs[@]} )); then
      restart_services restart "${svcs[@]}" || return 5
    fi
  fi
}

"$mode"
