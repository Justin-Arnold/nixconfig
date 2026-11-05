# sqlite-backup: consistent, encrypted backups of SQLite databases and the
# files that belong with them, and the restore that puts them back.
#
#   run                    Snapshot every database with SQLite's online backup,
#                          check its integrity, pack the snapshots, the extra
#                          files and a metadata.json into one age-encrypted
#                          archive on the destination, read it back, prune old
#                          archives, and report to the push URL.
#   push up|down MESSAGE   Report to the push URL (the failure unit uses this).
#   restore ARCHIVE [--force]
#                          Decrypt and check an archive, stop the services that
#                          own the files, move the live files aside and install
#                          the archived ones.
#   list                   Archives on the destination, newest first.
#
# Snapshots are taken as the database file's owner, so SQLite never leaves a
# root-owned -wal or -shm file behind that the application can't open.
#
# The spec (SQLITE_BACKUP_SPEC) is JSON written by the NixOS module. The push
# URL contains a token and is never printed.
set -euo pipefail
umask 077

: "${SQLITE_BACKUP_SPEC:?spec file}"
spec="$SQLITE_BACKUP_SPEC"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"
CURL_BIN="${CURL_BIN:-curl}"
OWNER_SWITCH="${SQLITE_BACKUP_OWNER_SWITCH:-1}"
NOBODY_UID="${SQLITE_BACKUP_NOBODY_UID:-65534}"

name="$(jq -r .name "$spec")"
dest="$(jq -r .destination "$spec")"
work_root="$(jq -r .workDir "$spec")"
identity="${SQLITE_BACKUP_IDENTITY:-$(jq -r '.identityFile // empty' "$spec")}"

log() { printf 'sqlite-backup: %s\n' "$*" >&2; }
die() {
  log "$*"
  exit 1
}

entries() { # .databases or .files -> "name<TAB>path" lines
  jq -r --arg k "$1" '.[$k] | to_entries[] | "\(.key)\t\(.value)"' "$spec"
}

as_owner() { # uid:gid command...
  local owner="$1"
  shift
  if [[ "$OWNER_SWITCH" == "1" ]]; then
    setpriv --reuid="${owner%:*}" --regid="${owner#*:}" --clear-groups -- "$@"
  else
    "$@"
  fi
}

integrity() {
  sqlite3 "$1" 'PRAGMA integrity_check;' 2>&1 | head -n 5
}

push() { # up|down message
  local url_file url
  url_file="$(jq -r '.pushUrlFile // empty' "$spec")"
  [[ -n "$url_file" ]] || return 0
  if [[ ! -r "$url_file" ]]; then
    log "push URL file $url_file is missing; not reporting"
    return 0
  fi
  url="$(tr -d '\n' < "$url_file")"
  # Kuma's copy-paste URL already carries ?status=up&msg=OK&ping=; drop it.
  url="${url%%\?*}"
  if ! "$CURL_BIN" -fsS --max-time 20 -o /dev/null -G \
      --data-urlencode "status=$1" --data-urlencode "msg=$2" "$url"; then
    log "could not report '$1' to the push URL"
  fi
}

require_destination() {
  local types
  [[ -d "$dest" ]] || die "destination $dest does not exist"
  types="$(jq -r '(.mountTypes // []) | join(",")' "$spec")"
  if [[ -n "$types" ]]; then
    # Look inside first so an automount actually mounts.
    ls "$dest" >/dev/null 2>&1 || true
    if ! "$FINDMNT_BIN" -n -t "$types" --mountpoint "$dest" >/dev/null 2>&1; then
      die "$dest is not mounted ($types); refusing to write backups to the local disk"
    fi
  fi
}

archives() {
  find "$dest" -maxdepth 1 -type f -name "${name}-*.tar.zst.age" -printf '%f\n' | sort -r
}

prune() {
  local keep_days keep_min i=0 f
  keep_days="$(jq -r .keepDays "$spec")"
  keep_min="$(jq -r .keepMin "$spec")"
  while IFS= read -r f; do
    i=$((i + 1))
    ((i > keep_min)) || continue
    if [[ -n "$(find "$dest/$f" -mtime +"$keep_days" -print)" ]]; then
      rm -f -- "${dest:?}/$f"
      log "pruned $f"
    fi
  done < <(archives)
  find "$dest" -maxdepth 1 -type f -name "${name}-*.tar.zst.age.tmp" -mtime +1 -delete
}

cmd_run() {
  local ts work archive db_name db_path f_name f_path owner stage check
  local recipients=() age_args=() r
  require_destination

  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  archive="$dest/$name-$ts.tar.zst.age"
  [[ ! -e "$archive" ]] || die "$archive already exists"

  mkdir -p "$work_root"
  # Database owners need to reach their staging directories, so every level
  # above them is traversable (but not listable).
  chmod 0711 "$work_root"
  work="$(mktemp -d "$work_root/run.XXXXXX")"
  # shellcheck disable=SC2064 # expand now
  trap "rm -rf '$work'" EXIT
  chmod 0711 "$work"
  mkdir -m 0711 "$work/db"
  mkdir "$work/files"
  : > "$work/databases.jsonl"

  while IFS=$'\t' read -r db_name db_path; do
    [[ -f "$db_path" ]] || die "database $db_name not found at $db_path"
    owner="$(stat -c '%u:%g' "$db_path")"
    # systemd id-maps a state directory owned by nobody into the service
    # (DynamicUser does this), so that owner isn't the service's user.
    [[ "${owner%:*}" != "$NOBODY_UID" ]] \
      || die "database $db_name at $db_path is owned by nobody, so systemd id-maps its directory. Stop the service, chown the directory to the service's user, and start it again."
    stage="$work/db/.stage-$db_name"
    install -d -m 0700 -o "${owner%:*}" -g "${owner#*:}" "$stage"
    as_owner "$owner" sqlite3 "$db_path" ".timeout 15000" ".backup '$stage/$db_name.sqlite'"
    mv "$stage/$db_name.sqlite" "$work/db/$db_name.sqlite"
    rmdir "$stage"
    check="$(integrity "$work/db/$db_name.sqlite")"
    [[ "$check" == "ok" ]] || die "integrity check failed for $db_name: $check"
    jq -cn --arg n "$db_name" --arg p "$db_path" --arg o "$owner" \
      --argjson b "$(stat -c %s "$work/db/$db_name.sqlite")" \
      '{($n): {path: $p, owner: $o, bytes: $b, integrity: "ok"}}' >> "$work/databases.jsonl"
  done < <(entries databases)

  while IFS=$'\t' read -r f_name f_path; do
    if [[ -e "$f_path" ]]; then
      cp -a -- "$f_path" "$work/files/$f_name"
    else
      log "note: $f_name ($f_path) does not exist; skipped"
    fi
  done < <(entries files)

  jq -n --arg name "$name" --arg created "$ts" --arg host "$(uname -n)" \
    --slurpfile s "$spec" --slurpfile dbs "$work/databases.jsonl" \
    '{name: $name, created: $created, host: $host, metadata: $s[0].metadata,
      databases: ($dbs | add // {}), files: ($s[0].files | keys)}' > "$work/metadata.json"
  rm "$work/databases.jsonl"

  mapfile -t recipients < <(jq -r '.recipients[]' "$spec")
  if [[ -n "$identity" ]]; then
    recipients+=("$(age-keygen -y "$identity")")
  fi
  ((${#recipients[@]} > 0)) || die "no age recipients configured"
  for r in "${recipients[@]}"; do
    age_args+=(-r "$r")
  done

  tar --numeric-owner -C "$work" -cf - metadata.json db files | zstd -q -T0 | age "${age_args[@]}" > "$archive.tmp"
  mv "$archive.tmp" "$archive"
  # Read back what landed on the destination, not what we meant to write.
  if [[ -n "$identity" ]]; then
    age -d -i "$identity" "$archive" | zstd -dcq | tar -tf - >/dev/null \
      || die "$archive could not be read back"
  fi

  prune
  log "wrote $archive"
  push up "backup $ts ok, $(du -h "$archive" | cut -f1)"
}

cmd_restore() {
  local archive="${1:-}" force="${2:-}" tmp ts n live dir owner mode archived suffix
  local units=()
  [[ -n "$archive" && -f "$archive" ]] || die "usage: sqlite-backup restore <archive> [--force]"
  [[ -n "$identity" && -r "$identity" ]] || die "set SQLITE_BACKUP_IDENTITY to an age identity that can decrypt the archive"

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand now
  trap "rm -rf '$tmp'" EXIT
  age -d -i "$identity" "$archive" | zstd -dcq | tar --numeric-owner -xf - -C "$tmp" \
    || die "cannot decrypt or unpack $archive"
  [[ -f "$tmp/metadata.json" ]] || die "$archive is not a sqlite-backup archive"
  [[ "$(jq -r .name "$tmp/metadata.json")" == "$name" ]] \
    || die "$archive belongs to $(jq -r .name "$tmp/metadata.json"), not $name"

  while IFS=$'\t' read -r n live; do
    [[ -f "$tmp/db/$n.sqlite" ]] || die "$archive has no copy of database $n"
    [[ "$(integrity "$tmp/db/$n.sqlite")" == "ok" ]] || die "database $n in $archive fails its integrity check"
  done < <(entries databases)

  # Files that must already match, such as the fingerprint of an encryption
  # key: restoring data the current key can't decrypt helps nobody.
  while IFS= read -r n; do
    live="$(jq -r --arg n "$n" '.files[$n]' "$spec")"
    archived="$tmp/files/$n"
    if [[ -e "$live" && -e "$archived" ]] && ! cmp -s "$live" "$archived"; then
      if [[ "$force" == "--force" ]]; then
        log "WARNING: $n in the archive differs from $live; restoring anyway (--force)"
      else
        die "$n in the archive differs from $live, so this data was made with a different key or identity; refusing (--force overrides)"
      fi
    fi
  done < <(jq -r '.mustMatch[]' "$spec")

  mapfile -t units < <(jq -r '.units[]' "$spec")
  if ((${#units[@]} > 0)); then
    "$SYSTEMCTL_BIN" stop "${units[@]}"
  fi

  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  while IFS=$'\t' read -r n live; do
    dir="$(dirname "$live")"
    mkdir -p "$dir"
    owner="$(stat -c '%u:%g' "$dir")"
    mode=0600
    [[ -e "$live" ]] && mode="$(stat -c %a "$live")"
    for suffix in "" -wal -shm -journal; do
      if [[ -e "$live$suffix" ]]; then
        mv -- "$live$suffix" "$live$suffix.pre-restore-$ts"
      fi
    done
    install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$tmp/db/$n.sqlite" "$live"
  done < <(entries databases)

  while IFS=$'\t' read -r n live; do
    [[ -e "$tmp/files/$n" ]] || continue
    if [[ -e "$live" ]]; then
      mv -- "$live" "$live.pre-restore-$ts"
    fi
    cp -a -- "$tmp/files/$n" "$live"
  done < <(entries files)

  if ((${#units[@]} > 0)); then
    "$SYSTEMCTL_BIN" start "${units[@]}"
  fi
  log "restored $(basename "$archive"); the replaced files are kept as *.pre-restore-$ts"
}

case "${1:-}" in
  run) cmd_run ;;
  push)
    [[ "${2:-}" == "up" || "${2:-}" == "down" ]] || die "usage: sqlite-backup push up|down MESSAGE"
    push "$2" "${3:-}"
    ;;
  restore)
    shift
    cmd_restore "$@"
    ;;
  list)
    require_destination
    archives
    ;;
  *)
    die "usage: sqlite-backup run | push up|down MESSAGE | restore ARCHIVE [--force] | list"
    ;;
esac
