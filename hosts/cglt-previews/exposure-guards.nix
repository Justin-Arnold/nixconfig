# Each case breaks the preview host's exposure policy (configuration.nix),
# or something its deploys depend on, and evaluating the example
# (eval-test.nix) with it must fail. flake/checks.nix runs them as
# .#checks.<system>.cglt-previews-exposure-guards.
{ lib, example }:
let
  sshd = settings: { systemd.services.sshd.serviceConfig = settings; };
  traefik = settings: { services.traefik.staticConfigOptions = settings; };
  http = settings: { services.traefik.dynamicConfigOptions.http = settings; };
  container = name: settings: { virtualisation.oci-containers.containers.${name} = settings; };
in
{
  # The config forces allowedTCPPorts empty, so only a stronger
  # override gets a port past it.
  extra-public-tcp-port = { networking.firewall.allowedTCPPorts = lib.mkOverride 40 [ 3000 ]; };
  extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 9999 ]; };
  interface-opening = { networking.firewall.interfaces.ens18.allowedTCPPorts = [ 3000 ]; };
  trusted-interface = { networking.firewall.trustedInterfaces = [ "docker0" ]; };
  extra-accept-rule = { networking.firewall.extraCommands = "iptables -w -A nixos-fw -p tcp --dport 3000 -j nixos-fw-accept"; };
  http-open-to-lan = { networking.firewall.extraCommands = "iptables -w -A nixos-fw -p tcp -s 10.0.0.0/24 --dport 80 -j nixos-fw-accept"; };
  egress-rules-dropped = { networking.firewall.extraCommands = lib.mkForce "iptables -w -A nixos-fw -p tcp -s 10.0.0.72 --dport 80 -j nixos-fw-accept"; };
  nftables-firewall = { networking.nftables.enable = true; };
  hawser-agent-enabled = { roles.docker.dockhandManaged.enable = lib.mkForce true; };
  beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
  docker-without-zfs = { systemd.services.docker.requires = lib.mkForce [ "docker.socket" ]; };
  no-auto-upgrade = { profiles.server.autoUpgrade.enable = lib.mkForce false; };
  sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
  traefik-https-entrypoint = traefik { entryPoints.websecure.address = ":443"; };
  traefik-dashboard = traefik { api.dashboard = true; };
  traefik-trusts-lan = traefik { entryPoints.web.forwardedHeaders.trustedIPs = lib.mkForce [ "10.0.0.0/24" ]; };
  traefik-trusts-anyone = traefik { entryPoints.web.forwardedHeaders.insecure = true; };
  traefik-exposed-by-default = traefik { providers.docker.exposedByDefault = lib.mkForce true; };
  traefik-second-provider = traefik { providers.http.endpoint = "http://10.0.0.20/routes"; };
  dockhand-without-gate = http { routers.dockhand.middlewares = lib.mkForce [ "preview-noindex" ]; };
  dockhand-without-warpgate = http { routers.dockhand.middlewares = lib.mkForce [ "ops-auth" "preview-noindex" ]; };
  files-without-warpgate = http { routers.files.middlewares = lib.mkForce [ "ops-auth" "preview-noindex" ]; };
  files-without-gate = http { routers.files.middlewares = lib.mkForce [ "warpgate-only" "preview-noindex" ]; };
  mail-without-warpgate = http { routers.mail.middlewares = lib.mkForce [ "ops-auth" "preview-noindex" ]; };
  mail-without-gate = http { routers.mail.middlewares = lib.mkForce [ "warpgate-only" "preview-noindex" ]; };
  warpgate-allowlist-widened = http { middlewares.warpgate-only.ipAllowList.sourceRange = lib.mkForce [ "0.0.0.0/0" ]; };
  warpgate-allowlist-remote-addr = http { middlewares.warpgate-only.ipAllowList.ipStrategy = lib.mkForce { }; };
  ops-auth-not-basic-auth = http { middlewares.ops-auth = lib.mkForce { headers.customRequestHeaders.X-Gate = "open"; }; };
  ops-route-to-lan = http { services.mail.loadBalancer.servers = lib.mkForce [ { url = "http://10.0.0.20:80"; } ]; };
  extra-file-route = http { routers.lan = { rule = "Host(`lan.preview.commongoodlt.dev`)"; service = "mail"; }; };
  container-on-all-interfaces = container "mailpit" { ports = lib.mkForce [ "8025:8025" ]; };
  container-unpinned = container "mailpit" { image = lib.mkForce "axllent/mailpit:latest"; };
  filebrowser-exec-on = container "filebrowser" { cmd = lib.mkForce [ "--" "/bin/filebrowser" "--disableExec=false" ]; };
  filebrowser-as-root = container "filebrowser" { user = lib.mkForce "0:0"; };
  deploy-sudo-all = { security.sudo.extraRules = [ { users = [ "preview-deploy" ]; commands = [ "ALL" ]; } ]; };
  deploy-sudo-extra-command = { security.sudo.extraRules = [ { users = [ "preview-deploy" ]; commands = [ { command = "/run/current-system/sw/bin/mount"; options = [ "NOPASSWD" ]; } ]; } ]; };
  deploy-in-wheel = { users.users.preview-deploy.extraGroups = [ "wheel" ]; };
  deploy-nix-trusted = { nix.settings.trusted-users = [ "preview-deploy" ]; };
  deploy-nologin = { users.users.preview-deploy.shell = lib.mkForce "/run/current-system/sw/bin/nologin"; };
  deploy-key-with-options = { cgltPreviews.deploy.authorizedKeys = lib.mkForce [ "command=\"/bin/sh\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEvalTestOnly" ]; };
  deploy-port-open-to-lan = { networking.firewall.extraCommands = "iptables -w -A nixos-fw -p tcp -s 10.0.0.0/24 --dport 2222 -j nixos-fw-accept"; };
  sshd-third-port = { services.openssh.ports = [ 2223 ]; };
  sshd-listen-address = { services.openssh.listenAddresses = [ { addr = "0.0.0.0"; port = 2223; } ]; };
  sshd-config-after-match = { services.openssh.extraConfig = lib.mkOrder 2000 "AllowTcpForwarding yes"; };
  fail2ban-enabled = { services.fail2ban.enable = true; };
  sshguard-enabled = { services.sshguard.enable = true; };
  # A mount namespace hides the jobs' ZFS mounts from Docker;
  # no_new_privs breaks sudo.
  sshd-socket-activated = { services.openssh.startWhenNeeded = true; };
  sshd-private-mounts = sshd { PrivateMounts = true; };
  sshd-protect-system = sshd { ProtectSystem = "strict"; };
  sshd-no-new-privileges = sshd { NoNewPrivileges = true; };
}
