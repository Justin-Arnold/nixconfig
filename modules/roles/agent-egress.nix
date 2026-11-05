# Outbound filter for agent users (roles.agentEgress).
#
# An agent may reach the public Internet (model providers, the web) and this
# host's own services, but not the rest of the private network: not the NAS,
# Proxmox, OPNsense or the other VMs. A LAN destination an agent does need is
# listed in `allow`, one address and its ports at a time.
#
# The filter matches the uid that owns each socket (nftables `meta skuid`),
# so it covers everything an agent's user starts, MCP servers and ssh
# included, and leaves every other user alone. `groups` does the same by
# gid, for users that come in numbers, like nix's build users. A refused
# connection gets an ICMP "administratively prohibited" back, so it fails at
# once instead of timing out, and the kernel log records it with the uid, at
# most ten a minute.
#
# Loopback stays open: this host's services each ask for a key the agents
# don't have, and Hermes talks to itself over loopback. DNS needs no rule
# either; it goes to systemd-resolved on 127.0.0.53, which asks upstream as
# its own user.
#
# Turning this on moves the whole host firewall to nftables
# (networking.nftables.enable). The networking.firewall options work as
# before.
{ config, lib, ... }:
let
  cfg = config.roles.agentEgress;

  # Private, shared (CGNAT), link-local, multicast and reserved ranges; the
  # LAN is in them, and so is the 169.254.169.254 metadata address. A routed
  # IPv6 LAN prefix would need adding here.
  blockedV4 = [ "10.0.0.0/8" "100.64.0.0/10" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "224.0.0.0/3" ];
  blockedV6 = [ "fc00::/7" "fe80::/10" "ff00::/8" ];

  set = items: "{ ${lib.concatStringsSep ", " items} }";
  uidOf = user: toString config.users.users.${user}.uid;
  gidOf = group: toString config.users.groups.${group}.gid;

  allowRules = lib.concatLists (lib.mapAttrsToList (name: a:
    let
      who = lib.optionalString (a.users != null) "meta skuid ${set (map uidOf a.users)} ";
      rule = proto: ports: "${who}ip daddr ${a.address} ${proto} dport ${set (map toString ports)} accept comment \"${name}\"";
    in
    lib.optional (a.tcpPorts != [ ]) (rule "tcp" a.tcpPorts)
    ++ lib.optional (a.udpPorts != [ ]) (rule "udp" a.udpPorts)
  ) cfg.allow);

  singleAddress = address: builtins.match "[0-9]{1,3}(\\.[0-9]{1,3}){3}" address != null;
in
{
  options.roles.agentEgress = {
    enable = lib.mkEnableOption "the outbound filter for agent users";

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "hermes-coordinator" ];
      description = "Users whose connections are filtered. Each needs a fixed uid.";
    };

    groups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "nixbld" ];
      description = "Groups whose connections are filtered, by the socket's gid. Each needs a fixed gid.";
    };

    allow = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = lib.types.str;
            example = "10.0.0.63";
            description = "One IPv4 address in the LAN.";
          };
          tcpPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
          };
          udpPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
          };
          users = lib.mkOption {
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            default = null;
            description = "The filtered users that may connect; null for all of them.";
          };
        };
      });
      default = { };
      example = lib.literalExpression ''
        { inference = { address = "10.0.0.63"; tcpPorts = [ 443 ]; users = [ "hermes-researcher" ]; }; }
      '';
      description = "LAN destinations the agents may reach, by name. The name shows in `nft list`.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = cfg.users != [ ] || cfg.groups != [ ];
          message = "roles.agentEgress: no users or groups to filter.";
        }
      ]
      ++ map (user: {
        assertion = (config.users.users.${user} or { }).uid or null != null;
        message = "roles.agentEgress: ${user} needs to be a user with a fixed uid.";
      }) cfg.users
      ++ map (group: {
        assertion = (config.users.groups.${group} or { }).gid or null != null;
        message = "roles.agentEgress: ${group} needs to be a group with a fixed gid.";
      }) cfg.groups
      ++ lib.concatLists (lib.mapAttrsToList (name: a: [
        {
          assertion = singleAddress a.address && (a.tcpPorts != [ ] || a.udpPorts != [ ]);
          message = "roles.agentEgress.allow.${name}: one address and its ports, never a range or a whole host.";
        }
        {
          assertion = a.users == null || lib.all (u: lib.elem u cfg.users) a.users;
          message = "roles.agentEgress.allow.${name}: every user it names must be in roles.agentEgress.users.";
        }
      ]) cfg.allow);

    networking.nftables.enable = true;
    networking.nftables.tables.agent-egress = {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority filter; policy accept;
          ${lib.optionalString (cfg.users != [ ]) "meta skuid ${set (map uidOf cfg.users)} jump agent"}
          ${lib.optionalString (cfg.groups != [ ]) "meta skgid ${set (map gidOf cfg.groups)} jump agent"}
        }

        chain agent {
          ct state established,related accept
          oifname "lo" accept
          ${lib.concatStringsSep "\n  " allowRules}
          ip daddr ${set blockedV4} jump refuse
          ip6 daddr ${set blockedV6} jump refuse
        }

        chain refuse {
          limit rate 10/minute burst 5 packets log prefix "agent-egress refused: " level info flags skuid
          counter reject with icmpx admin-prohibited
        }
      '';
    };
  };
}
