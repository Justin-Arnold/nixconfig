{ config, lib, ... }:
let
  facts = config.lab118.facts;
  hasIPv6 = facts.ipv6.address != null;
  orPlaceholder = value: placeholder: if value == null then placeholder else value;

  # Docker's default bridge. Pinned so resolved can listen on it for containers.
  dockerBridgeAddress = "172.17.0.1";
in
{
  # Static addressing from facts.nix; nothing here depends on the lab.
  networking.useDHCP = false;

  systemd.network.networks."10-wan" = {
    matchConfig.MACAddress = orPlaceholder facts.macAddress "00:00:00:00:00:00";
    address = [
      "${facts.ipv4.address}/${toString (orPlaceholder facts.ipv4.prefixLength 32)}"
    ] ++ lib.optional hasIPv6 "${facts.ipv6.address}/${toString facts.ipv6.prefixLength}";
    routes = [
      {
        Gateway = orPlaceholder facts.ipv4.gateway "0.0.0.0";
        GatewayOnLink = true;
      }
    ] ++ lib.optional hasIPv6 {
      Gateway = facts.ipv6.gateway;
      GatewayOnLink = true;
    };
    networkConfig = {
      DHCP = "no";
      IPv6AcceptRA = false;
    };
    linkConfig.RequiredForOnline = "routable";
  };

  # Public resolvers. Lab names (*.host.internal) are routed to lab DNS over
  # WireGuard by wireguard.nix, so a lab outage cannot break general DNS.
  networking.nameservers = [
    "9.9.9.9"
    "1.1.1.1"
  ] ++ lib.optionals hasIPv6 [
    "2620:fe::fe"
    "2606:4700:4700::1111"
  ];

  # Containers use the host's resolved, so they get the same split DNS instead
  # of Docker copying every upstream server (including lab DNS) into them.
  services.resolved.settings.Resolve = {
    DNSStubListenerExtra = dockerBridgeAddress;
    # Local-network name discovery has no place on an Internet-facing host.
    LLMNR = "false";
    MulticastDNS = "false";
  };
  roles.docker.daemonSettings = {
    bip = "${dockerBridgeAddress}/16";
    dns = [ dockerBridgeAddress ];
  };
  networking.firewall.interfaces.docker0 = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
