# Used only by the agents flake checks: no real SOPS file, so the full
# configuration and every assertion can be evaluated on any machine. Every
# lab source and GitHub are on here with example values, so the checks cover
# them before their credentials exist.
{ lib, pkgs, ... }:
{
  sops.defaultSopsFile = lib.mkForce "/nonexistent/agents.yaml";
  sops.validateSopsFiles = lib.mkForce false;

  roles.hermesAgents.observe = {
    proxmox = lib.mkForce {
      urls = [ "https://10.0.0.14:8006" "https://10.0.0.18:8006" ];
      caFile = pkgs.writeText "proxmox-ca.pem" "an example CA";
    };
    beszel = lib.mkForce { url = "https://beszel.servicestack.xyz"; user = "agents@servicestack.xyz"; };
    kuma = lib.mkForce { url = "http://10.118.0.1:3002"; slug = "agents"; };
    alerta = lib.mkForce { url = "http://10.118.0.1:5000"; };
  };
  roles.hermesAgents.instances = {
    coordinator.github.enable = lib.mkForce true;
    researcher.github.enable = lib.mkForce true;
  };
  agents.events.enable = lib.mkForce true;
  # The bridge with both channels, under example user IDs.
  agents.boardBridge = {
    enable = lib.mkForce true;
    telegram.userId = lib.mkForce "1111";
    discord.userId = lib.mkForce "222222222222222222";
  };
}
