# openclaw: the chat front door to the lab's agents, a NixOS VM on the
# Proxmox cluster. It runs the OpenClaw gateway as the concierge
# (openclaw.nix), whose only tool is Paperclip on the agents VM, behind nginx
# with a Let's Encrypt certificate (endpoints.nix). It holds its own ChatGPT
# login, its Paperclip key and the chat bots' tokens, and nothing else. Like
# agents it can move between nodes: disk and cloud-init drive on nas-shared,
# an HA resource, a CPU model every node has
# (infra/terranix/hosts/openclaw.nix). See docs/openclaw/REFERENCE.md.
{ config, lib, inputs, sops-nix, ... }:
let
  macMiniKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com";
  agentsVm = "10.0.0.152";

  fw = config.networking.firewall;
  publicTcpPorts = lib.sort lib.lessThan (lib.unique fw.allowedTCPPorts);
  publicUdpPorts = lib.unique fw.allowedUDPPorts;
  interfaceRules = lib.filterAttrs
    (_: i: i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ] || i.allowedTCPPortRanges != [ ] || i.allowedUDPPortRanges != [ ])
    fw.interfaces;
  # The NixOS firewall always trusts the loopback interface.
  trustedInterfaces = lib.subtractLists [ "lo" ] fw.trustedInterfaces;

  oc = config.roles.openclaw;
  s = oc.renderedSettings;
  at = path: lib.attrByPath path null s;
  deny = at [ "tools" "deny" ];
  mustDeny = [ "gateway" "openclaw" "plugins" "cron" "skill_workshop" "browser" "group:runtime" "group:fs" "group:web" ];
  missingDenies = lib.subtractLists (if deny == null then [ ] else deny) mustDeny;
  mcpServers = lib.attrNames (lib.attrByPath [ "mcp" "servers" ] { } s);

  # A channel that's on takes DMs from the listed ids only, and no groups.
  channels = lib.attrByPath [ "channels" ] { } s;
  openChannels = lib.attrNames (lib.filterAttrs (_: c: (c.enabled or true) && !(
    (c.dmPolicy or null) == "allowlist"
    && (c.allowFrom or [ ]) != [ ]
    && !(lib.elem "*" (c.allowFrom or [ ]))
    && (c.groupPolicy or null) == "disabled"
  )) channels);

  egress = config.roles.agentEgress;
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./endpoints.nix
      ./backup.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ./openclaw.nix
      ../../modules/roles/openclaw.nix
      ../../modules/roles/agent-egress.nix
      ../../modules/roles/sqlite-backup.nix
      ../../modules/roles/beszel-agent.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "openclaw";
    stateVersion = "26.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  # The MAC is fixed in Terraform; OPNsense keeps a DHCP reservation for it
  # (10.0.0.154), so the address survives migration and HA recovery.
  networking.useDHCP = lib.mkDefault true;

  profiles.server = {
    # Only the operator's Mac Mini key; lab controllers are not trusted here.
    authorizedKeys = [ macMiniKey ];
    # Upgrades are deliberate: nix flake update + nix run .#switch.
    autoUpgrade.enable = false;
  };

  # No Home Manager user environment: keeps the closure small and the host
  # independent of user-tool downloads.
  home-manager.users = lib.mkForce { };

  services.journald.settings.Journal = {
    SystemMaxUse = "1G";
    MaxRetentionSec = "30day";
  };

  ############################################################
  ## Users and secrets (SOPS, host-scoped key)
  ############################################################
  # justin is key-only; root has a password for the Proxmox console only
  # (SSH root login is off).
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

  sops = {
    defaultSopsFile = ../../secrets/hosts/openclaw.yaml;
    # Dedicated host identity, installed by `nix run .#install` with
    # HOST_AGE_KEY_FILE. The operator key is never copied to this host.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];

    secrets."root/console-password-hash".neededForUsers = true;
  };

  ############################################################
  ## Workloads
  ############################################################
  # The gateway reaches the Internet (its models, the chat platforms) and
  # Paperclip on the agents VM, and nothing else on the LAN.
  roles.agentEgress = {
    enable = true;
    users = [ oc.user ];
    allow.paperclip = {
      address = agentsVm;
      tcpPorts = [ 443 ];
    };
  };

  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
  };

  # The TrueNAS share for ./backup.nix, by address so the mount never waits
  # on DNS.
  openclaw.backup.nfsDevice = "10.0.0.20:/mnt/Main/backups/openclaw-backups";

  ############################################################
  ## Guards
  ############################################################
  # The exposure policy. .#checks.<system>.openclaw-exposure-guards breaks
  # each of these and fails unless evaluation refuses it.
  assertions = [
    {
      assertion = publicTcpPorts == [ 22 80 443 ];
      message = "openclaw: public TCP ports must be exactly 22, 80, 443 (got ${toString publicTcpPorts}).";
    }
    {
      assertion = publicUdpPorts == [ ];
      message = "openclaw: no public UDP ports (got ${toString publicUdpPorts}).";
    }
    {
      assertion = interfaceRules == { } && trustedInterfaces == [ ];
      message = "openclaw: no per-interface firewall openings or trusted interfaces (got ${toString (lib.attrNames interfaceRules ++ trustedInterfaces)}).";
    }
    {
      assertion = !config.virtualisation.docker.enable && !config.virtualisation.podman.enable;
      message = "openclaw: no container engine; the gateway runs no sandboxes.";
    }
    {
      assertion = at [ "gateway" "bind" ] == "loopback" && at [ "gateway" "mode" ] == "local";
      message = "openclaw: the gateway binds loopback; nginx is the only way in.";
    }
    {
      assertion = at [ "gateway" "auth" "mode" ] == "token"
        && lib.hasPrefix "\${" (toString (at [ "gateway" "auth" "token" ]))
        && at [ "gateway" "auth" "allowTailscale" ] == false;
      message = "openclaw: the gateway takes a token, from SOPS through the environment, never a literal.";
    }
    {
      assertion = at [ "gateway" "trustedProxies" ] == [ "127.0.0.1" ];
      message = "openclaw: only this host's nginx is a trusted proxy.";
    }
    {
      assertion = at [ "gateway" "terminal" "enabled" ] == false && at [ "gateway" "cliAgents" "enabled" ] == false;
      message = "openclaw: the Control UI's terminal and CLI agents stay off; they'd open a shell here.";
    }
    {
      assertion = at [ "tools" "profile" ] == "minimal"
        && lib.all (t: t == "bundle-mcp") (lib.attrByPath [ "tools" "alsoAllow" ] [ ] s)
        && lib.attrByPath [ "tools" "allow" ] null s == null;
      message = "openclaw: tools stay on the minimal profile, plus MCP and nothing else.";
    }
    {
      assertion = missingDenies == [ ];
      message = "openclaw: these tools must stay denied: ${toString missingDenies}.";
    }
    {
      assertion = at [ "tools" "exec" "mode" ] == "deny" && at [ "tools" "elevated" "enabled" ] == false;
      message = "openclaw: no exec, elevated or not.";
    }
    {
      assertion = at [ "browser" "enabled" ] == false
        && at [ "tools" "web" "search" "enabled" ] == false
        && at [ "tools" "web" "fetch" "enabled" ] == false;
      message = "openclaw: no browser, web search or web fetch.";
    }
    {
      assertion = at [ "security" "installPolicy" "enabled" ] == true
        && at [ "skills" "allowBundled" ] == [ ]
        && lib.attrByPath [ "skills" "load" "extraDirs" ] [ ] s == [ ];
      message = "openclaw: no skills, bundled or installed, and no plugin installs.";
    }
    {
      assertion = lib.attrByPath [ "hooks" "enabled" ] false s == false;
      message = "openclaw: hooks stay off; they're how outside content reaches the agent unasked.";
    }
    {
      assertion = lib.subtractLists [ "paperclip" ] mcpServers == [ ];
      message = "openclaw: Paperclip is the only MCP server (got ${toString mcpServers}).";
    }
    {
      assertion = openChannels == [ ];
      message = "openclaw: an enabled channel takes DMs from an allowlist of ids and no groups (not so: ${toString openChannels}).";
    }
    {
      assertion = egress.enable && lib.elem oc.user egress.users;
      message = "openclaw: the gateway goes through the egress filter.";
    }
    {
      assertion = !config.sops.validateSopsFiles || builtins.pathExists config.sops.defaultSopsFile;
      message = ''
        openclaw: secrets/hosts/openclaw.yaml doesn't exist yet. Generate the
        host age key, add its recipient to .sops.yaml, create the file with
        sops and `git add` it (docs/openclaw/REFERENCE.md, "Secrets").
      '';
    }
  ];
}
