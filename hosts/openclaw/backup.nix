# Nightly backups of the concierge (roles.sqliteBackup) to an NFS share on
# the NAS: the gateway's SQLite databases (devices, pairings and the ChatGPT
# login; the agent's sessions and memory) and the rest of its workspace.
# They hold credentials, so archives are encrypted to this host's key and
# the operator key, and an Uptime Kuma push monitor hears about every run.
{ config, lib, ... }:
let
  cfg = config.openclaw.backup;
  mountPoint = "/mnt/openclaw-backups";
  state = config.roles.openclaw.stateDir;

  # Operator key: can decrypt every archive for recovery off this host.
  operatorAgeRecipient = "age1ljfvx33psxcat4wwjpq6u26f5fv9jzntg8z266mhykpxh78upalqxfflz3";
in
{
  options.openclaw.backup = {
    nfsDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nas.host.internal:/volume1/backups/openclaw";
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
        message = "openclaw: openclaw.backup.nfsDevice isn't set. Give it the NAS export for backups (docs/openclaw/REFERENCE.md, \"Backups\").";
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
      name = "openclaw";
      destination = mountPoint;
      databases = {
        gateway = "${state}/state/openclaw.sqlite";
        concierge = "${state}/agents/main/agent/openclaw-agent.sqlite";
      };
      files = {
        # The agent's own memory files. AGENTS.md, SOUL.md and IDENTITY.md
        # come from the repo on every start.
        workspace = "${state}/workspace";
        credentials = "${state}/credentials";
      };
      recipients = [ operatorAgeRecipient ];
      units = [ "openclaw-gateway.service" ];
      metadata.openclawPackage = config.roles.openclaw.package.name;
      pushUrlFile = config.sops.secrets."kuma/backup-push-url".path;
    };
  };
}
