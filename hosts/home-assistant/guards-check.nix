{
  pkgs,
  lib,
  host,
}:
let
  refused =
    module:
    !(builtins.tryEval
      (host.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath
    ).success;
  results = lib.mapAttrs (_: refused) {
    extra-tcp = {
      networking.firewall.allowedTCPPorts = [ 8123 ];
    };
    extra-udp = {
      networking.firewall.allowedUDPPorts = [ 5540 ];
    };
    extra-range = {
      networking.firewall.allowedUDPPortRanges = [
        {
          from = 1;
          to = 65535;
        }
      ];
    };
    trusted-interface = {
      networking.firewall.trustedInterfaces = [ "ens18" ];
    };
    interface-opening = {
      networking.firewall.interfaces.ens18.allowedTCPPorts = [ 8123 ];
    };
    backend-public = {
      services.home-assistant.config.http.server_host = lib.mkForce "0.0.0.0";
    };
    matter-public = {
      services.matter-server.extraArgs.listen-address = lib.mkForce [ "0.0.0.0" ];
    };
    matter-firewall = {
      services.matter-server.openFirewall = true;
    };
    proxy-bypass = {
      services.nginx.virtualHosts."home-assistant.servicestack.xyz".locations."/".extraConfig =
        lib.mkForce "allow all;";
    };
    extra-location = {
      services.nginx.virtualHosts."home-assistant.servicestack.xyz".locations."/other".return = "200";
    };
    radio-unscoped = {
      networking.firewall.extraInputRules = lib.mkForce "";
    };
    ipv6-off = {
      networking.enableIPv6 = false;
    };
    autonomous-switch = {
      profiles.server.autoUpgrade.enable = true;
    };
    no-matter-backup = {
      roles.sqliteBackup.files.matter = lib.mkForce "/wrong";
    };
    no-backup-quiesce = {
      systemd.services.sqlite-backup.serviceConfig.ExecStartPre = lib.mkForce [ ];
    };
    no-backup-restart = {
      systemd.services.sqlite-backup.serviceConfig.ExecStopPost = lib.mkForce [ ];
    };
    no-restore-quiesce = {
      roles.sqliteBackup.units = lib.mkForce [ ];
    };
    sops-missing = {
      sops.validateSopsFiles = lib.mkOverride 40 true;
    };
    beszel-listener = {
      services.beszel.agent.openFirewall = true;
    };
  };
in
assert lib.assertMsg (lib.all lib.id (
  lib.attrValues results
)) "home-assistant: an exposure/backup guard failed to refuse an unsafe variant";
pkgs.writeText "home-assistant-exposure-guards" (builtins.toJSON results)
