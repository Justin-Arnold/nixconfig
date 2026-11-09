# Offline recovery test: synthetic data, temporary test key and fake service
# control. No real secrets, NAS, radios or host services are accessed.
{ pkgs, lib }:
let
  backup = (import ../../modules/roles/sqlite-backup/lib.nix { inherit pkgs lib; }).package;
  control = pkgs.writeShellScript "fake-service-control" ''
    printf '%s\n' "$*" >> "$CALLS"
  '';
in
pkgs.runCommand "home-assistant-backup-recovery"
  {
    nativeBuildInputs = with pkgs; [
      age
      sqlite
      jq
      coreutils
      gnugrep
    ];
  }
  ''
    export HOME=$TMPDIR
    root=$PWD
    mkdir -p live/recorder live/hass/.storage live/matter live/cache dest work
    age-keygen -o test.key 2>/dev/null
    sqlite3 live/recorder/recorder.sqlite "create table events (value text); insert into events values ('before');"
    sqlite3 live/hass/zigbee.db "create table devices (value text); insert into devices values ('paired');"
    printf '%s\n' 'synthetic-config-entry' > live/hass/.storage/core.config_entries
    printf '%s\n' 'synthetic-fabric' > live/matter/chip.json
    printf '%s\n' 'synthetic-paa-cache' > live/cache/cert
    jq -n --arg root "$root" '{
      name: "home-assistant", destination: ($root + "/dest"), workDir: ($root + "/work"),
      identityFile: ($root + "/test.key"), recipients: [], mountTypes: null, pushUrlFile: null,
      databases: {recorder: ($root + "/live/recorder/recorder.sqlite")},
      files: {hass: ($root + "/live/hass"), matter: ($root + "/live/matter"), "matter-cache": ($root + "/live/cache")},
      units: ["home-assistant.service", "matter-server.service"],
      mustMatch: [], metadata: {}, keepDays: 30, keepMin: 7
    }' > spec.json
    export SQLITE_BACKUP_SPEC=$PWD/spec.json SQLITE_BACKUP_OWNER_SWITCH=0
    export CALLS=$PWD/control.log SYSTEMCTL_BIN=${control}
    ${backup}/bin/sqlite-backup run
    sqlite3 live/recorder/recorder.sqlite "update events set value='after';"
    printf '%s\n' 'changed' > live/hass/.storage/core.config_entries
    printf '%s\n' 'changed' > live/matter/chip.json
    ${backup}/bin/sqlite-backup restore "$root"/dest/*.tar.zst.age
    test "$(sqlite3 live/recorder/recorder.sqlite 'select value from events')" = before
    test "$(sqlite3 live/hass/zigbee.db 'select value from devices')" = paired
    grep -qx synthetic-config-entry live/hass/.storage/core.config_entries
    grep -qx synthetic-fabric live/matter/chip.json
    grep -qx synthetic-paa-cache live/cache/cert
    grep -qx 'stop home-assistant.service matter-server.service' control.log
    grep -qx 'start home-assistant.service matter-server.service' control.log
    printf '%s\n' 'Synthetic recorder, Zigbee DB, HA .storage, Matter fabric/cache restore passed; service control was fake.' > "$out"
  ''
