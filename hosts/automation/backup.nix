# Nightly consistent backups of n8n's database (roles.sqliteBackup) to an NFS
# share on the NAS. Archives are encrypted to this host's key and the operator
# key, so either can restore them, and an Uptime Kuma push monitor hears about
# every run.
#
# The encryption key isn't in the archive: it's in
# secrets/hosts/automation.yaml. The archive carries its fingerprint, which n8n
# writes before every start, so a restore refuses data the current key can't
# decrypt. Workflows and credentials can also be put back from the repo and
# SOPS with scripts/automation/n8n-apply.py; what only the backup has is the
# execution history.
{ config, lib, pkgs, ... }:
let
  cfg = config.automation.backup;
  mountPoint = "/mnt/automation-backups";
  data = "${config.services.n8n.environment.N8N_USER_FOLDER}/.n8n";
  keyFingerprint = "${config.services.n8n.environment.N8N_USER_FOLDER}/.encryption-key.sha256";

  # Operator key: can decrypt every archive for recovery off this host.
  operatorAgeRecipient = "age1ljfvx33psxcat4wwjpq6u26f5fv9jzntg8z266mhykpxh78upalqxfflz3";

  writeFingerprint = pkgs.writeShellScript "n8n-key-fingerprint" ''
    set -eu
    ${pkgs.coreutils}/bin/sha256sum <"$CREDENTIALS_DIRECTORY/n8n_encryption_key_file" \
      | ${pkgs.coreutils}/bin/cut -d' ' -f1 >${keyFingerprint}
  '';
in
{
  options.automation.backup = {
    nfsDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nas.host.internal:/volume1/backups/automation";
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
        message = "automation: automation.backup.nfsDevice isn't set. Give it the NAS export for backups (docs/automation/REFERENCE.md, \"Backups\").";
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

    systemd.services.n8n.serviceConfig.ExecStartPre = [ "${writeFingerprint}" ];

    sops.secrets."kuma/backup-push-url" = { };

    roles.sqliteBackup = {
      enable = true;
      name = "automation";
      destination = mountPoint;
      databases.n8n = "${data}/database.sqlite";
      files.n8n-key-fingerprint = keyFingerprint;
      mustMatch = [ "n8n-key-fingerprint" ];
      recipients = [ operatorAgeRecipient ];
      units = [ "n8n.service" ];
      metadata.n8nVersion = config.services.n8n.package.version;
      pushUrlFile = config.sops.secrets."kuma/backup-push-url".path;
    };
  };
}
