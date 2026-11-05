# dashboard: the lab's monitoring dashboard, a NixOS VM on the Proxmox
# cluster. It runs Homarr (the dashboard) and the Beszel hub (host and GPU
# metrics). It's built to move between nodes: disk and cloud-init drive on
# nas-shared, an HA resource, a CPU model every node has, and nothing passed
# through (infra/terranix/hosts/dashboard.nix). See docs/dashboard/REFERENCE.md.
{ config, lib, inputs, sops-nix, ... }:
let
  macMiniKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com";

  fw = config.networking.firewall;
  publicTcpPorts = lib.sort lib.lessThan (lib.unique fw.allowedTCPPorts);
  publicUdpPorts = lib.unique fw.allowedUDPPorts;
  interfaceRules = lib.filterAttrs
    (_: i: i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ] || i.allowedTCPPortRanges != [ ] || i.allowedUDPPortRanges != [ ])
    fw.interfaces;
  # The NixOS firewall always trusts the loopback interface.
  trustedInterfaces = lib.subtractLists [ "lo" ] fw.trustedInterfaces;

  containers = config.virtualisation.oci-containers.containers;
  containerPorts = lib.concatMap (c: c.ports) (lib.attrValues containers);
  homarrContainer = containers.homarr;

  # Every nginx server block that can reach Homarr must include the MCP/OAuth
  # guard and may only have the locations below, so nothing can match a
  # request before the guard does.
  homarrUpstream = ":${toString config.roles.homarr.hostPort}";
  reachesHomarr = vh: lib.any (l: l.proxyPass != null && lib.hasSuffix homarrUpstream l.proxyPass) (lib.attrValues vh.locations);
  homarrVhosts = lib.filterAttrs (_: reachesHomarr) config.services.nginx.virtualHosts;
  unguardedVhosts = lib.attrNames (lib.filterAttrs (_: vh: !(lib.hasInfix "homarr-guard.conf" vh.extraConfig)) homarrVhosts);
  extraHomarrLocations = lib.concatLists (lib.mapAttrsToList
    (name: vh: map (l: "${name} ${l}") (lib.subtractLists [ "/" "= /api/health/live" ] (lib.attrNames vh.locations)))
    homarrVhosts);
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./beszel-hub.nix
      ./endpoints.nix
      ./backup.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/docker.nix
      ../../modules/roles/homarr.nix
      ../../modules/roles/sqlite-backup.nix
      ../../modules/roles/beszel-agent.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "dashboard";
    stateVersion = "26.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  # The MAC is fixed in Terraform; OPNsense keeps a DHCP reservation for it,
  # so the address survives migration and HA recovery.
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

  ############################################################
  ## Users and secrets (SOPS, host-scoped key)
  ############################################################
  # justin is key-only; root has a password for the Proxmox console only
  # (SSH root login is off).
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

  sops = {
    defaultSopsFile = ../../secrets/hosts/dashboard.yaml;
    # Dedicated host identity, installed by `nix run .#install` with
    # HOST_AGE_KEY_FILE. The operator key is never copied to this host.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];

    secrets."root/console-password-hash".neededForUsers = true;
    # Read once by the container entrypoint (as root) through a read-only mount.
    secrets."homarr/secret-encryption-key".mode = "0400";
  };

  ############################################################
  ## Workloads
  ############################################################
  roles.docker = {
    enable = true;
    # No Hawser agent: it would hold the Docker socket on a host that stores
    # credentials for the rest of the lab.
    dockhandManaged.enable = false;
    # Pinned so nginx and Homarr agree on where the container's traffic
    # comes from (Homarr trusts this gateway's X-Forwarded-For).
    daemonSettings.bip = "172.17.0.1/16";
  };

  roles.homarr = {
    enable = true;
    image = "ghcr.io/homarr-labs/homarr:v2.10.1@sha256:2844201f11ce28b98183728dea2261de2b4fd8ed5480a4eef0b7977cc1a08dc0";
    baseUrl = "https://dashboard.servicestack.xyz";
    secretEncryptionKeyFile = config.sops.secrets."homarr/secret-encryption-key".path;
    # The Beszel integration talks to the hub through nginx on this host,
    # with the real certificate, whatever the container's DNS says.
    extraHosts = [ "beszel.servicestack.xyz:host-gateway" ];
  };

  # This host's own metrics, straight to the hub on loopback.
  roles.beszelAgent = {
    enable = true;
    hubUrl = "http://127.0.0.1:${toString config.services.beszel.hub.port}";
    tokenSecret = "beszel/agent-token";
  };

  # The TrueNAS share for ./backup.nix, by address so the mount never waits
  # on DNS.
  dashboard.backup.nfsDevice = "10.0.0.20:/mnt/Main/backups/dashboard-backups";

  ############################################################
  ## Guards
  ############################################################
  # The exposure policy. .#checks.<system>.dashboard-exposure-guards breaks
  # each of these and fails unless evaluation refuses it.
  assertions = [
    {
      assertion = publicTcpPorts == [ 22 80 443 ];
      message = "dashboard: public TCP ports must be exactly 22, 80, 443 (got ${toString publicTcpPorts}).";
    }
    {
      assertion = publicUdpPorts == [ ];
      message = "dashboard: no public UDP ports (got ${toString publicUdpPorts}).";
    }
    {
      assertion = interfaceRules == { } && trustedInterfaces == [ ];
      message = "dashboard: no per-interface firewall openings or trusted interfaces (got ${toString (lib.attrNames interfaceRules ++ trustedInterfaces)}).";
    }
    {
      # Ports Docker publishes skip the NixOS firewall.
      assertion = lib.all (p: lib.hasPrefix "127.0.0.1:" p) containerPorts;
      message = "dashboard: every container port must be published on 127.0.0.1 (got ${toString containerPorts}).";
    }
    {
      assertion = config.services.beszel.hub.host == "127.0.0.1";
      message = "dashboard: the Beszel hub must listen on 127.0.0.1; nginx publishes it.";
    }
    {
      assertion = !config.roles.docker.dockhandManaged.enable;
      message = "dashboard: no Hawser agent; it would hold the Docker socket on this host.";
    }
    {
      assertion = !(lib.any (v: lib.hasInfix "docker.sock" v || lib.hasInfix "podman.sock" v) homarrContainer.volumes)
        && (homarrContainer.environment.ENABLE_DOCKER or "") == "false";
      message = "dashboard: Homarr gets no container socket and keeps ENABLE_DOCKER=false.";
    }
    {
      assertion = !(homarrContainer.environment ? SECRET_ENCRYPTION_KEY);
      message = "dashboard: SECRET_ENCRYPTION_KEY must come from a file (SECRET_ENCRYPTION_KEY_FILE), never the container environment.";
    }
    {
      assertion = homarrVhosts != { } && unguardedVhosts == [ ];
      message = "dashboard: nginx server blocks reaching Homarr without the MCP guard: ${toString unguardedVhosts}.";
    }
    {
      assertion = extraHomarrLocations == [ ];
      message = "dashboard: locations that could match before the MCP guard: ${lib.concatStringsSep ", " extraHomarrLocations}.";
    }
    {
      assertion = !config.sops.validateSopsFiles || builtins.pathExists config.sops.defaultSopsFile;
      message = ''
        dashboard: secrets/hosts/dashboard.yaml doesn't exist yet. Generate the
        host age key, add its recipient to .sops.yaml, create the file with
        sops and `git add` it (docs/dashboard/REFERENCE.md, "Secrets").
      '';
    }
  ];
}
