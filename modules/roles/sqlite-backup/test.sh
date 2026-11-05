# Behavioural tests for sqlite-backup. Runs anywhere bash, sqlite3, age, zstd
# and GNU tar exist (the flake check runs it on macOS and Linux). curl,
# findmnt and systemctl are fakes that record their calls. Owner switching is
# off because the tests don't run as root.
#
# usage: test.sh <sqlite-backup binary>
set -euo pipefail

TOOL="$1"
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

mkdir -p "$T/bin" "$T/calls" "$T/live/app" "$T/live/hub/certs" "$T/dest" "$T/work" "$T/out"
age-keygen -o "$T/host.key" 2>/dev/null
age-keygen -o "$T/operator.key" 2>/dev/null

cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CALLS/curl"
FAKE
cat >"$T/bin/findmnt" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CALLS/findmnt"
[[ -n "${FAKE_MOUNTED:-}" ]]
FAKE
cat >"$T/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$CALLS/systemctl"
FAKE
chmod +x "$T/bin/"*

APP="$T/live/app/db.sqlite"
HUB="$T/live/hub/data.db"
PIN="$T/live/app/key.sha256"
sqlite3 "$APP" "PRAGMA journal_mode=WAL; CREATE TABLE boards(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO boards(name) VALUES ('overview'), ('network');" >/dev/null
sqlite3 "$HUB" "PRAGMA journal_mode=WAL; CREATE TABLE systems(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO systems(name) VALUES ('dashboard');" >/dev/null
echo "pinned-key-fingerprint" >"$PIN"
echo "certificate" >"$T/live/hub/certs/ca.crt"
echo "https://intake.example/api/push/TOKEN?status=up&msg=OK&ping=" >"$T/push-url"

write_spec() { # spec-path app-db-path
  jq -n --arg dest "$T/dest" --arg work "$T/work" --arg id "$T/host.key" \
    --arg op "$(age-keygen -y "$T/operator.key")" --arg app "$2" --arg hub "$HUB" \
    --arg pin "$PIN" --arg certs "$T/live/hub/certs" --arg push "$T/push-url" \
    '{name: "dash", destination: $dest, workDir: $work, identityFile: $id,
      mountTypes: ["nfs", "nfs4"], pushUrlFile: $push,
      databases: {homarr: $app, beszel: $hub},
      files: {"key-pin": $pin, certs: $certs, missing: "/nonexistent/file"},
      mustMatch: ["key-pin"], recipients: [$op], keepDays: 30, keepMin: 3,
      units: ["docker-homarr.service", "beszel-hub.service"],
      metadata: {homarrImage: "ghcr.io/homarr-labs/homarr@sha256:abc"}}' >"$1"
}
write_spec "$T/spec.json" "$APP"

export CALLS="$T/calls" SQLITE_BACKUP_SPEC="$T/spec.json" SQLITE_BACKUP_OWNER_SWITCH=0
export CURL_BIN="$T/bin/curl" FINDMNT_BIN="$T/bin/findmnt" SYSTEMCTL_BIN="$T/bin/systemctl"

run() {
  rm -f "$CALLS"/*
  RC=0
  "$TOOL" "$@" >"$T/out.log" 2>&1 || RC=$?
}
rc_is() { [[ "$RC" == "$1" ]]; }
rc_not_zero() { [[ "$RC" != 0 ]]; }
called_with() { grep -qF -- "$2" "$CALLS/$1" 2>/dev/null; }
not_called_with() { ! grep -qF -- "$2" "$CALLS/$1" 2>/dev/null; }
not_called() { [[ ! -s "$CALLS/$1" ]]; }
output_has() { grep -qF -- "$1" "$T/out.log"; }
archive_count() { find "$T/dest" -name 'dash-*.tar.zst.age' | wc -l | tr -d ' '; }
newest() { find "$T/dest" -name 'dash-*.tar.zst.age' | sort | tail -n 1; }
rows() { sqlite3 "$1" "SELECT count(*) FROM $2;"; }
unpack() { # archive identity
  rm -rf "$T/out" && mkdir -p "$T/out"
  age -d -i "$2" "$1" | zstd -dcq | tar -xf - -C "$T/out"
}

echo "== refuses an unmounted destination"
run run
check "exits non-zero" rc_not_zero
check "  ...says why" output_has "is not mounted"
check "  ...writes nothing" [ "$(archive_count)" = 0 ]
check "  ...reports nothing" not_called curl

echo "== refuses a database owned by nobody"
FAKE_MOUNTED=1 SQLITE_BACKUP_NOBODY_UID="$(id -u)" run run
check "exits non-zero" rc_not_zero
check "  ...says why" output_has "is owned by nobody"
check "  ...writes nothing" [ "$(archive_count)" = 0 ]
check "  ...reports nothing" not_called curl

echo "== backup while the database is being written"
(for i in $(seq 1 300); do sqlite3 "$APP" ".timeout 5000" "INSERT INTO boards(name) VALUES ('w$i');"; done) &
writer=$!
FAKE_MOUNTED=1 run run
wait "$writer"
check "exits 0" rc_is 0
check "writes one archive" [ "$(archive_count)" = 1 ]
check "leaves no temporary file" [ -z "$(find "$T/dest" -name '*.tmp')" ]
check "reports up" called_with curl "status=up"
check "  ...to the push URL without Kuma's query string" called_with curl " https://intake.example/api/push/TOKEN"
check "  ...and never with the original query" not_called_with curl "msg=OK&ping"
ARCHIVE="$(newest)"
unpack "$ARCHIVE" "$T/operator.key"
check "the operator key decrypts it" [ -f "$T/out/metadata.json" ]
check "the snapshot passes integrity_check" [ "$(sqlite3 "$T/out/db/homarr.sqlite" 'PRAGMA integrity_check;')" = ok ]
check "  ...and has the rows written before the backup" [ "$(rows "$T/out/db/homarr.sqlite" boards)" -ge 2 ]
check "the second database is in it" [ "$(rows "$T/out/db/beszel.sqlite" systems)" = 1 ]
check "metadata records the image" [ "$(jq -r .metadata.homarrImage "$T/out/metadata.json")" = "ghcr.io/homarr-labs/homarr@sha256:abc" ]
check "metadata records the integrity result" [ "$(jq -r .databases.homarr.integrity "$T/out/metadata.json")" = ok ]
check "extra files are included" cmp -s "$T/out/files/key-pin" "$PIN"
check "directories are included" [ -f "$T/out/files/certs/ca.crt" ]
check "missing files are skipped" [ ! -e "$T/out/files/missing" ]
unpack "$ARCHIVE" "$T/host.key"
check "the host key decrypts it too" [ -f "$T/out/metadata.json" ]
check "nothing is left in the work directory" [ -z "$(ls -A "$T/work")" ]
check "the work directory is traversable, not listable, for database owners" [ "$(stat -c %a "$T/work")" = 711 ]

echo "== retention"
for i in 0 1 2 3 4 5; do
  touch -d "60 days ago" "$T/dest/dash-2020010${i}T000000Z.tar.zst.age"
done
sleep 1
FAKE_MOUNTED=1 run run
check "exits 0" rc_is 0
check "keeps the newest keepMin archives" [ "$(archive_count)" = 3 ]
check "  ...including an old one inside keepMin" [ -f "$T/dest/dash-20200105T000000Z.tar.zst.age" ]
check "  ...and prunes the old ones beyond it" [ ! -e "$T/dest/dash-20200104T000000Z.tar.zst.age" ]

echo "== a corrupt database"
echo "this is not a database" >"$T/live/app/broken.sqlite"
write_spec "$T/spec-broken.json" "$T/live/app/broken.sqlite"
before="$(archive_count)"
sleep 1
SQLITE_BACKUP_SPEC="$T/spec-broken.json" FAKE_MOUNTED=1 run run
check "exits non-zero" rc_not_zero
check "  ...writes no archive" [ "$(archive_count)" = "$before" ]
check "  ...never reports up" not_called_with curl "status=up"

echo "== push down"
run push down "backup failed"
check "reports down" called_with curl "status=down"

echo "== restore"
sqlite3 "$APP" "DELETE FROM boards;"
run restore "$ARCHIVE"
check "exits 0" rc_is 0
check "brings the rows back" [ "$(rows "$APP" boards)" -ge 2 ]
check "keeps the replaced database aside" [ -n "$(find "$T/live/app" -name 'db.sqlite.pre-restore-*')" ]
check "leaves no stale -wal next to the restored database" [ ! -e "$APP-wal" ]
check "the restored database passes integrity_check" [ "$(sqlite3 "$APP" 'PRAGMA integrity_check;')" = ok ]
check "stops the services first" called_with systemctl "stop docker-homarr.service beszel-hub.service"
check "  ...and starts them again" called_with systemctl "start docker-homarr.service beszel-hub.service"
check "restores directories" [ -f "$T/live/hub/certs/ca.crt" ]

echo "== restore with a different key"
echo "another-key-fingerprint" >"$PIN"
sqlite3 "$APP" "DELETE FROM boards;"
run restore "$ARCHIVE"
check "refuses" rc_not_zero
check "  ...and says why" output_has "made with a different key"
check "  ...without stopping anything" not_called systemctl
check "  ...or touching the live database" [ "$(rows "$APP" boards)" = 0 ]
run restore "$ARCHIVE" --force
check "--force restores anyway" [ "$(rows "$APP" boards)" -ge 2 ]

echo "== restore refuses another host's archive"
jq '.name = "other"' "$T/spec.json" >"$T/spec-other.json"
SQLITE_BACKUP_SPEC="$T/spec-other.json" run restore "$ARCHIVE"
check "refuses" rc_not_zero

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
