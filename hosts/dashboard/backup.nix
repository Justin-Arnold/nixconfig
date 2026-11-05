# Nightly consistent backups of Homarr and the Beszel hub (roles.sqliteBackup)
# to an NFS share on the NAS. Archives are encrypted to this host's key and
# the operator key, so either can restore them, and an Uptime Kuma push
# monitor hears about every run.
#
# Homarr's encryption key isn't in the archive: it's in
# secrets/hosts/dashboard.yaml (and 1Password). The archive carries its
# fingerprint, so a restore refuses data the current key can't decrypt. The
# hub's identity key comes from SOPS too, so only its database is backed up.
{ config, lib, ... }:
let
  cfg = config.dashboard.backup;
  mountPoint = "/mnt/dashboard-backups";
  homarrData = config.roles.homarr.dataDir;
  hubData = "${config.services.beszel.hub.dataDir}/beszel_data";

  # Operator key: can decrypt every archive for recovery off this host.
  operatorAgeRecipient = "age1ljfvx33psxcat4wwjpq6u26f5fv9jzntg8z266mhykpxh78upalqxfflz3";
in
{
  options.dashboard.backup = {
    nfsDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nas.host.internal:/volume1/backups/dashboard";
      description = "NFS export the archives are written to. The host refuses to build without it.";
    };

    nfsOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nfsvers=4.1" ];
      description = "Mount options for the export, on top of the automount defaults.";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.nfsDevice != null;
        message = "dashboard: dashboard.backup.nfsDevice isn't set. Give it the NAS export for backups (docs/dashboard/REFERENCE.md, \"Backups\").";
      }
    ];

    # Mounted on first use and dropped when idle, so a NAS outage only fails
    # the backup run instead of hanging boot or other services.
    fileSystems.${mountPoint} = lib.mkIf (cfg.nfsDevice != null) {
      device = cfg.nfsDevice;
      fsType = "nfs";
      options = cfg.nfsOptions ++ [
        "x-systemd.automount"
        "noauto"
        "nofail"
        "_netdev"
        "x-systemd.idle-timeout=10min"
        "x-systemd.mount-timeout=30s"
        # Writes go to a temporary name and are read back before they count.
        "soft"
        "timeo=100"
        "retrans=3"
        "nosuid"
        "nodev"
        "noexec"
      ];
    };

    sops.secrets."kuma/backup-push-url" = { };

    roles.sqliteBackup = {
      enable = true;
      name = "dashboard";
      destination = mountPoint;
      databases = {
        homarr = "${homarrData}/db/db.sqlite";
        beszel = "${hubData}/data.db";
      };
      files = {
        homarr-key-fingerprint = "${homarrData}/.secret-encryption-key.sha256";
        homarr-certificates = "${homarrData}/trusted-certificates";
      };
      mustMatch = [ "homarr-key-fingerprint" ];
      recipients = [ operatorAgeRecipient ];
      units = [ "docker-homarr.service" "beszel-hub.service" ];
      metadata = {
        homarrImage = config.roles.homarr.image;
        beszelVersion = config.services.beszel.hub.package.version;
      };
      pushUrlFile = config.sops.secrets."kuma/backup-push-url".path;
    };
  };
}
