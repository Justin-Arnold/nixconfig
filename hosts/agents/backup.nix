# Nightly backups of Paperclip (roles.sqliteBackup) to an NFS share on the
# NAS: a pg_dump of its database and a copy of its data directory. Archives
# are encrypted to this host's key and the operator key, so either can
# restore them, and an Uptime Kuma push monitor hears about every run.
#
# The master key isn't in the archive: it's in secrets/hosts/agents.yaml (and
# 1Password). The archive carries its fingerprint, so a restore refuses data
# the current key can't decrypt.
{ config, lib, ... }:
let
  cfg = config.agents.backup;
  mountPoint = "/mnt/agents-backups";
  paperclip = config.roles.paperclip;

  # Operator key: can decrypt every archive for recovery off this host.
  operatorAgeRecipient = "age1ljfvx33psxcat4wwjpq6u26f5fv9jzntg8z266mhykpxh78upalqxfflz3";
in
{
  options.agents.backup = {
    nfsDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nas.host.internal:/volume1/backups/agents";
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
        message = "agents: agents.backup.nfsDevice isn't set. Give it the NAS export for backups (docs/agents/REFERENCE.md, \"Backups\").";
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
      name = "agents";
      destination = mountPoint;
      postgresDatabases.paperclip = "paperclip";
      files = {
        paperclip-key-fingerprint = paperclip.masterKeyPinFile;
        # Instance config, attachments and agent home files. The master key
        # comes from SOPS, so it isn't in here.
        paperclip-home = paperclip.dataDir;
      };
      mustMatch = [ "paperclip-key-fingerprint" ];
      recipients = [ operatorAgeRecipient ];
      units = [ "podman-paperclip.service" ];
      metadata.paperclipImage = paperclip.image;
      pushUrlFile = config.sops.secrets."kuma/backup-push-url".path;
    };
  };
}
