{
  config,
  lib,
  pkgs,
  ...
}:
let
  mountPoint = "/mnt/home-assistant-backups";
  units = [
    "home-assistant.service"
    "matter-server.service"
  ];
  systemctl = "${config.systemd.package}/bin/systemctl";
  preflight = pkgs.writeShellScript "home-assistant-backup-preflight" ''
    set -eu
    test -f /var/lib/home-assistant-recorder/recorder.sqlite
    test -d /var/lib/hass/.storage
    test -d /var/lib/private/matter-server
    test -d /var/cache/private/matter-server
  '';
  stop = "${systemctl} stop ${lib.concatStringsSep " " units}";
  start = "${systemctl} start ${lib.concatStringsSep " " units}";
in
{
  fileSystems.${mountPoint} = {
    device = "10.0.0.20:/mnt/Main/backups/home-assistant-backups";
    fsType = "nfs";
    options = [
      "nfsvers=4.1"
      "x-systemd.automount"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.idle-timeout=10min"
      "x-systemd.mount-timeout=30s"
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
    name = "home-assistant";
    destination = mountPoint;
    databases.recorder = "/var/lib/home-assistant-recorder/recorder.sqlite";
    files = {
      hass = toString config.services.home-assistant.configDir;
      # DynamicUser exposes /var/lib/matter-server as a symlink: archive the
      # real private directory, so cp -a doesn't just save a dangling link.
      matter = "/var/lib/private/matter-server";
      matter-cache = "/var/cache/private/matter-server";
    };
    recipients = [ "age1ljfvx33psxcat4wwjpq6u26f5fv9jzntg8z266mhykpxh78upalqxfflz3" ];
    inherit units;
    metadata = {
      homeAssistantVersion = config.services.home-assistant.package.version;
      matterServerVersion = config.services.matter-server.package.version;
    };
    pushUrlFile = config.sops.secrets."kuma/backup-push-url".path;
  };
  # Consistency across recorder, pairing/config files and Matter's fabric.
  # ExecStopPost runs on failure too. These are generated unit commands, not
  # actions performed by an agent while preparing this PR.
  systemd.services.sqlite-backup.serviceConfig = {
    ExecStartPre = [
      "${preflight}"
      stop
    ];
    ExecStopPost = [ start ];
    TimeoutStartSec = "30min";
  };
  assertions = [
    {
      assertion =
        config.systemd.services.sqlite-backup.serviceConfig.ExecStartPre == [
          "${preflight}"
          stop
        ]
        && config.systemd.services.sqlite-backup.serviceConfig.ExecStopPost == [ start ]
        && config.roles.sqliteBackup.units == units;
      message = "home-assistant: backup must quiesce both applications and always restart them, and restore must stop both.";
    }
    {
      assertion =
        config.roles.sqliteBackup.databases.recorder == "/var/lib/home-assistant-recorder/recorder.sqlite"
        && config.roles.sqliteBackup.files.hass == "/var/lib/hass"
        && config.roles.sqliteBackup.files.matter == "/var/lib/private/matter-server";
      message = "home-assistant: backups need consistent recorder, full HA state and actual Matter fabric data.";
    }
  ];
}
