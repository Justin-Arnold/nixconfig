# Each case breaks openclaw's exposure policy (configuration.nix), and
# evaluating the example (eval-test.nix) with it must fail. flake/checks.nix
# runs them as .#checks.<system>.openclaw-exposure-guards.
{ lib, example }:
let
  oc = settings: { roles.openclaw.settings = settings; };
  vhost = "openclaw.servicestack.xyz";
in
{
  extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 18789 ]; };
  extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 5353 ]; };
  interface-opening = { networking.firewall.interfaces.ens18.allowedTCPPorts = [ 18789 ]; };
  trusted-interface = { networking.firewall.trustedInterfaces = [ "ens18" ]; };
  docker-enabled = { virtualisation.docker.enable = true; };
  podman-enabled = { virtualisation.podman.enable = true; };
  gateway-on-lan = oc { gateway.bind = lib.mkForce "lan"; };
  gateway-auth-off = oc { gateway.auth.mode = lib.mkForce "none"; };
  gateway-token-literal = oc { gateway.auth.token = lib.mkForce "a-literal-token-that-lands-in-the-store"; };
  gateway-tailscale-auth = oc { gateway.auth.allowTailscale = lib.mkForce true; };
  proxy-trusts-lan = oc { gateway.trustedProxies = lib.mkForce [ "10.0.0.0/24" ]; };
  terminal-on = oc { gateway.terminal.enabled = lib.mkForce true; };
  dangerously-flag = oc { gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback = true; };
  tools-full-profile = oc { tools.profile = lib.mkForce "full"; };
  tools-extra-allow = oc { tools.alsoAllow = lib.mkForce [ "bundle-mcp" "web_fetch" ]; };
  tools-shell-undenied = oc { tools.deny = lib.mkForce [ "gateway" "browser" ]; };
  exec-full = oc { tools.exec.mode = lib.mkForce "full"; };
  elevated-on = oc { tools.elevated.enabled = lib.mkForce true; };
  browser-on = oc { browser.enabled = lib.mkForce true; };
  web-fetch-on = oc { tools.web.fetch.enabled = lib.mkForce true; };
  skill-installs = oc { security.installPolicy.enabled = lib.mkForce false; };
  bundled-skills = oc { skills.allowBundled = lib.mkForce [ "github" ]; };
  skill-dirs = oc { skills.load.extraDirs = [ "/var/lib/openclaw/skills" ]; };
  hooks-on = oc { hooks.enabled = lib.mkForce true; };
  second-mcp-server = oc { mcp.servers.shell.command = "/bin/sh"; };
  discord-open-dms = oc { channels.discord = { dmPolicy = lib.mkForce "open"; allowFrom = lib.mkForce [ "*" ]; }; };
  discord-groups = oc { channels.discord.groupPolicy = lib.mkForce "allowlist"; };
  telegram-pairing = oc { channels.telegram.dmPolicy = lib.mkForce "pairing"; };
  egress-off = { roles.agentEgress.enable = lib.mkForce false; };
  extra-vhost = { services.nginx.virtualHosts."other.servicestack.xyz".locations."/".proxyPass = "http://127.0.0.1:18789"; };
  extra-location = { services.nginx.virtualHosts.${vhost}.locations."/api".proxyPass = "http://127.0.0.1:18789"; };
  location-open-to-all = { services.nginx.virtualHosts.${vhost}.locations."/".extraConfig = lib.mkForce "proxy_set_header X-Forwarded-For $remote_addr;"; };
  forwarded-chain = { services.nginx.virtualHosts.${vhost}.locations."/".extraConfig = lib.mkForce "deny all;\nproxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"; };
  backup-unset = { openclaw.backup.nfsDevice = lib.mkForce null; };
  sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
  beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
}
