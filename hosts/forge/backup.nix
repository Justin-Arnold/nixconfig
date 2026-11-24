# Nightly backups of Forgejo (roles.sqliteBackup) to an NFS share on the NAS:
# its SQLite database through SQLite's online backup, and a copy of the
# repositories, the generated secrets and the uploaded files. Archives are
# encrypted to this host's key and the operator key, so either can restore
# them, and an Uptime Kuma push monitor hears about every run.
#
# Forgejo's SECRET_KEY (custom/conf/secret_key) encrypts the second factors
# in the database, so it travels in the archive: a restore onto a new VM
# brings back the key with the data it opens. The archive is as private as
# the repositories already are, the vault's history among them.
{ config, lib, ... }:
let
  cfg = config.forge.backup;
  mountPoint = "/mnt/forge-backups";
  forgejo = config.services.forgejo;
  data = "${forgejo.stateDir}/data";

  # Operator key: can decrypt every archive for recovery off this host.
  operatorAgeRecipient = "age1ljfvx33psxcat4wwjpq6u26f5fv9jzntg8z266mhykpxh78upalqxfflz3";
in
{
  options.forge.backup = {
    nfsDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nas.host.internal:/volume1/backups/forge";
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
        message = "forge: forge.backup.nfsDevice isn't set. Give it the NAS export for backups (docs/forge/REFERENCE.md, \"Backups\").";
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
      name = "forge";
      destination = mountPoint;
      databases.forgejo = forgejo.database.path;
      files = {
        forgejo-repositories = forgejo.repositoryRoot;
        # SECRET_KEY, INTERNAL_TOKEN and the JWT secret, made on first start.
        forgejo-secrets = "${forgejo.customDir}/conf";
        forgejo-avatars = "${data}/avatars";
        forgejo-repo-avatars = "${data}/repo-avatars";
        forgejo-attachments = "${data}/attachments";
      };
      recipients = [ operatorAgeRecipient ];
      units = [ "forgejo.service" ];
      metadata.forgejoVersion = forgejo.package.version;
      pushUrlFile = config.sops.secrets."kuma/backup-push-url".path;
    };
  };
}
