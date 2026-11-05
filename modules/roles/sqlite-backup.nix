# modules/roles/sqlite-backup.nix
#
# Nightly, application-consistent backups of SQLite databases (SQLite's own
# online backup, not a copy of a file that's being written), together with the
# small files that belong to them, as one age-encrypted archive on a mounted
# share. Each run is read back after writing and reported to a push monitor;
# a failed run reports "down". `sqlite-backup restore <archive>` puts an
# archive back. See modules/roles/sqlite-backup/sqlite-backup.sh.
{ config, lib, pkgs, ... }:
let
  cfg = config.roles.sqliteBackup;
  backupLib = import ./sqlite-backup/lib.nix { inherit pkgs lib; };

  spec = backupLib.mkSpec {
    inherit (cfg) name destination databases files recipients keepDays keepMin mustMatch units metadata;
    workDir = "/var/lib/sqlite-backup";
    identityFile = cfg.identityFile;
    mountTypes = cfg.mountTypes;
    pushUrlFile = cfg.pushUrlFile;
  };

  tool = pkgs.writeShellScriptBin "sqlite-backup" ''
    exec env SQLITE_BACKUP_SPEC=${spec} SYSTEMCTL_BIN=${config.systemd.package}/bin/systemctl \
      ${backupLib.package}/bin/sqlite-backup "$@"
  '';
in
{
  options.roles.sqliteBackup = {
    enable = lib.mkEnableOption "consistent SQLite backups";

    name = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      description = "Archive name prefix: <name>-<UTC timestamp>.tar.zst.age.";
    };

    destination = lib.mkOption {
      type = lib.types.str;
      description = "Directory archives are written to (normally a network mount).";
    };

    mountTypes = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = [ "nfs" "nfs4" ];
      description = "Refuse to run unless destination is a mount of one of these types. null skips the check.";
    };

    databases = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = { homarr = "/var/lib/homarr/db/db.sqlite"; };
      description = "Name -> live SQLite database path.";
    };

    files = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Name -> file or directory copied into the archive as-is.";
    };

    mustMatch = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Names from `files` whose archived copy must equal the live file before
        a restore goes ahead, e.g. the fingerprint of an encryption key.
      '';
    };

    recipients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "age recipients archives are encrypted to, in addition to identityFile's.";
    };

    identityFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/var/lib/sops-nix/key.txt";
      description = "Host age identity: archives are also encrypted to it, read back with it, and restored with it by default.";
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Units stopped during a restore and started again afterwards.";
    };

    metadata = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Static values recorded in each archive's metadata.json (versions, image references).";
    };

    keepDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Archives older than this are pruned.";
    };

    keepMin = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "The newest archives are always kept, however old.";
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 03:15:00";
      description = "When to run (systemd OnCalendar).";
    };

    pushUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File holding an Uptime Kuma push URL. Each run reports up, a failed run reports down.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.recipients != [ ] || cfg.identityFile != null;
        message = "roles.sqliteBackup: archives need at least one age recipient.";
      }
      {
        assertion = lib.all (n: cfg.files ? ${n}) cfg.mustMatch;
        message = "roles.sqliteBackup.mustMatch may only name entries of roles.sqliteBackup.files.";
      }
    ];

    environment.systemPackages = [ tool ];

    systemd.services.sqlite-backup = {
      description = "Consistent SQLite backup to ${cfg.destination}";
      after = [ "network-online.target" "remote-fs.target" ];
      wants = [ "network-online.target" ];
      onFailure = [ "sqlite-backup-failed.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${tool}/bin/sqlite-backup run";
        StateDirectory = "sqlite-backup";
        # Traversable, not listable: snapshots are taken as each database's
        # owner into its own 0700 staging directory under here.
        StateDirectoryMode = "0711";
        PrivateTmp = true;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.services.sqlite-backup-failed = {
      description = "Report a failed SQLite backup";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${tool}/bin/sqlite-backup push down 'backup failed, see journalctl -u sqlite-backup'";
      };
    };

    systemd.timers.sqlite-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "10min";
      };
    };
  };
}
