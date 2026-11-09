{ config, lib, ... }:
let
  ha = config.services.home-assistant;
  matter = config.services.matter-server;
  # Discovery and device traffic only on the local LAN, not VPN/WAN/tunnel.
  radioRules = ''
    iifname "ens18" ip saddr 10.0.0.0/24 tcp dport 21063 accept
    iifname "ens18" ip saddr 10.0.0.0/24 udp dport { 5353, 5540 } accept
    iifname "ens18" ip6 saddr { fe80::/10, fc00::/7 } udp dport { 5353, 5540 } accept
  '';
in
{
  services.home-assistant = {
    enable = true;
    extraComponents = [
      "default_config"
      "zha"
      "matter"
      "thread"
      "esphome"
      "bluetooth"
      "homekit"
      "wyoming"
      "llama_cpp"
    ];
    config = {
      default_config = { };
      http = {
        server_host = "127.0.0.1";
        server_port = 8123;
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1" ];
      };
      recorder.db_url = "sqlite:////var/lib/home-assistant-recorder/recorder.sqlite";
      # UI-managed device/integration configuration is retained in .storage.
      # No entity filter: expose all HomeKit-supported entities.
      homekit = {
        name = "Home Assistant";
        port = 21063;
      };
    };
  };
  systemd.tmpfiles.rules = [ "d /var/lib/home-assistant-recorder 0700 hass hass -" ];
  systemd.services.home-assistant.serviceConfig.ReadWritePaths = [
    "/var/lib/home-assistant-recorder"
  ];
  services.matter-server = {
    enable = true;
    openFirewall = false;
    extraArgs = {
      listen-address = [ "127.0.0.1" ];
      primary-interface = "ens18";
    };
  };
  networking.enableIPv6 = true;
  networking.nftables.enable = true;
  networking.firewall.extraInputRules = radioRules;
  assertions = [
    {
      assertion =
        ha.config.http.server_host == "127.0.0.1"
        && ha.config.http.server_port == 8123
        && ha.config.http.trusted_proxies == [ "127.0.0.1" ]
        && ha.config.http.use_x_forwarded_for;
      message = "home-assistant: HTTP backend and trusted reverse proxy must stay loopback-only.";
    }
    {
      assertion =
        matter.port == 5580 && !matter.openFirewall && matter.extraArgs.listen-address == [ "127.0.0.1" ];
      message = "home-assistant: unauthenticated Matter WebSocket must stay loopback-only.";
    }
    {
      assertion =
        config.networking.nftables.enable && config.networking.firewall.extraInputRules == radioRules;
      message = "home-assistant: radio openings must retain the exact interface/source/port restrictions.";
    }
    {
      assertion = config.networking.enableIPv6;
      message = "home-assistant: Thread/Matter needs IPv6, not an IPv4-only workaround.";
    }
    {
      assertion = ha.config.homekit.port == 21063 && !(ha.config.homekit ? filter);
      message = "home-assistant: HomeKit Bridge uses the scoped port and all supported entities.";
    }
  ];
}
