# Beszel hub (services.beszel.hub): host and GPU metrics, their history and
# alerts. It listens on 127.0.0.1 only; nginx publishes it. Its data is
# PocketBase SQLite in /var/lib/beszel-hub/beszel_data.
#
# The hub's identity (beszel_data/id_ed25519) comes from SOPS instead of being
# generated on first start. Agents carry the matching public key, so they can
# be configured before the hub exists, and a rebuilt VM is still the same hub
# to every agent.
{ config, lib, pkgs, ... }:
let
  placeKey = pkgs.writeShellScript "beszel-hub-place-key" ''
    set -eu
    mkdir -p beszel_data
    install -m 0600 "$CREDENTIALS_DIRECTORY/hub-key" beszel_data/id_ed25519
  '';
in
{
  sops.secrets."beszel/hub-private-key".restartUnits = [ "beszel-hub.service" ];
  sops.secrets."kuma/beszel-heartbeat-url" = { };
  sops.templates."beszel-hub.env" = {
    # The hub pings this Kuma push monitor while it's healthy.
    content = "HEARTBEAT_URL=${config.sops.placeholder."kuma/beszel-heartbeat-url"}\n";
    restartUnits = [ "beszel-hub.service" ];
  };

  # A fixed UID instead of a dynamic one, so restored files and backups keep
  # a predictable owner.
  users.groups.beszel-hub.gid = 8090;
  users.users.beszel-hub = {
    isSystemUser = true;
    uid = 8090;
    group = "beszel-hub";
    description = "Beszel hub";
  };

  services.beszel.hub = {
    enable = true;
    host = "127.0.0.1";
    port = 8090;
    environment = {
      APP_URL = "https://beszel.servicestack.xyz";
      # One admin, plus a read-only user for Homarr that sees every system.
      SHARE_ALL_SYSTEMS = "true";
      HEARTBEAT_METHOD = "GET";
      # Seconds between pings; the Kuma push monitor allows a few misses.
      HEARTBEAT_INTERVAL = "60";
    };
    environmentFile = config.sops.templates."beszel-hub.env".path;
  };

  systemd.services.beszel-hub.serviceConfig = {
    # The nixpkgs unit uses DynamicUser, which keeps the data under
    # /var/lib/private (root only) and owned by nobody on disk. The backup
    # snapshots as the file's owner and couldn't reach it from there.
    DynamicUser = lib.mkForce false;
    Group = "beszel-hub";
    LoadCredential = [ "hub-key:${config.sops.secrets."beszel/hub-private-key".path}" ];
    ExecStartPre = lib.mkBefore [ "${placeKey}" ];
  };
}
