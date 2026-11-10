# cglt-previews: CGLT's pull-request previews, a NixOS VM on proxmox4 with
# its disk on the node's local ZFS storage, not HA by choice
# (infra/terranix/hosts/cglt-previews.nix). A pull request that names
# instances in its body (`pr-preview: cureum-adelstg, satchel-cps`) gets one
# Docker Compose project per instance, app and MySQL, whose data is a ZFS
# clone of a nightly golden copy of that instance. The monorepo's
# pr-preview.yaml and preview-snapshots.yaml drive it from GitHub-hosted
# runners, over SSH as preview-deploy on port 2222 (deploy.nix). Traefik routes
# https://<tag>-pr<N>.preview.commongoodlt.dev to each preview from Docker
# labels (ingress.nix); TLS ends on the Pangolin VPS, which reaches this VM
# through the home site's Newt. Dockhand, File Browser and Mailpit are the
# ops tools (ops.nix).
#
# Whoever holds the deploy key is root here (the docker group is root), so
# the host is fenced off from the rest of the lab: it may reach the gateway
# and the Internet, and its containers the same.
# See docs/cglt-previews/REFERENCE.md.
{ config, lib, pkgs, inputs, sops-nix, ... }:
let
  facts = import ./facts.nix;
  macMiniKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com";

  zfs = "${config.boot.zfs.package}/bin/zfs";
  root = facts.previewsRoot;

  fw = config.networking.firewall;
  interfaceRules = lib.filterAttrs
    (_: i: i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ] || i.allowedTCPPortRanges != [ ] || i.allowedUDPPortRanges != [ ])
    fw.interfaces;
  # The NixOS firewall always trusts the loopback interface.
  trustedInterfaces = lib.subtractLists [ "lo" ] fw.trustedInterfaces;

  ############################################################
  ## Firewall rules
  ############################################################
  # The only inbound openings: SSH from the LAN and the VPN, and Traefik's
  # port 80 and the deploy port from the Newt. Nothing goes in
  # allowedTCPPorts.
  inboundRules =
    map (source: "iptables -w -A nixos-fw -p tcp -s ${source} --dport 22 -j nixos-fw-accept") facts.adminSources
    ++ [
      "iptables -w -A nixos-fw -p tcp -s ${facts.newt} --dport 80 -j nixos-fw-accept"
      "iptables -w -A nixos-fw -p tcp -s ${facts.newt} --dport ${toString facts.deployPort} -j nixos-fw-accept"
    ];

  refuse = cmd: chain: prefix: reject: dest: [
    "${cmd} -w -A ${chain} -d ${dest} -m limit --limit 10/min --limit-burst 5 -j LOG --log-prefix \"${prefix}: \""
    "${cmd} -w -A ${chain} -d ${dest} -j REJECT --reject-with ${reject}"
  ];

  # Connections the host itself opens (deploy jobs included): loopback,
  # replies, the gateway and the Beszel hub, and nothing else in the private
  # ranges. Docker reaches containers on 172.16.0.0/12, which isn't blocked.
  hostEgressRules =
    [
      "iptables -w -D OUTPUT -j preview-egress 2>/dev/null || true"
      "iptables -w -F preview-egress 2>/dev/null || iptables -w -N preview-egress"
      "iptables -w -A preview-egress -o lo -j RETURN"
      "iptables -w -A preview-egress -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
      "iptables -w -A preview-egress -d ${facts.gateway} -j RETURN"
      "iptables -w -A preview-egress -d ${facts.beszelHub} -p tcp --dport 443 -j RETURN"
    ]
    ++ lib.concatMap (refuse "iptables" "preview-egress" "preview-egress" "icmp-admin-prohibited") facts.blockedV4
    ++ [
      "iptables -w -I OUTPUT 1 -j preview-egress"
      "ip6tables -w -D OUTPUT -j preview-egress 2>/dev/null || true"
      "ip6tables -w -F preview-egress 2>/dev/null || ip6tables -w -N preview-egress"
      "ip6tables -w -A preview-egress -o lo -j RETURN"
      "ip6tables -w -A preview-egress -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
    ]
    ++ lib.concatMap (refuse "ip6tables" "preview-egress" "preview-egress" "icmp6-adm-prohibited") facts.blockedV6
    ++ [ "ip6tables -w -I OUTPUT 1 -j preview-egress" ];

  # Forwarded traffic, i.e. containers. Docker jumps from FORWARD to
  # DOCKER-USER before its own rules and leaves the chain's contents alone, so
  # these hold whichever of Docker and the firewall starts first. Nothing from
  # outside may open a connection to a container (Traefik on the host is the
  # way in, so a `ports:` in a compose file opens nothing), and containers may
  # reach the gateway (DNS) and the Internet but not the lab.
  dockerUserRules =
    [
      "iptables -w -N DOCKER-USER 2>/dev/null || true"
      "iptables -w -F DOCKER-USER"
      "iptables -w -A DOCKER-USER -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN"
      "iptables -w -A DOCKER-USER ! -s ${facts.containerRange} -m conntrack --ctstate NEW -j DROP"
      "iptables -w -A DOCKER-USER -d ${facts.gateway} -j RETURN"
    ]
    ++ lib.concatMap (refuse "iptables" "DOCKER-USER" "preview-egress(container)" "icmp-admin-prohibited") facts.blockedV4
    ++ [ "iptables -w -A DOCKER-USER -j RETURN" ];

  extraLines = lib.filter (l: l != "") (lib.splitString "\n" fw.extraCommands);
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./deploy.nix
      ./ingress.nix
      ./ops.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/docker.nix
      ../../modules/roles/beszel-agent.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "cglt-previews";
    stateVersion = "26.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  # The MAC is fixed in Terraform; give it an OPNsense DHCP reservation
  # (docs/cglt-previews/REFERENCE.md, "Outside the repo").
  networking.useDHCP = lib.mkDefault true;

  profiles.server = {
    authorizedKeys = [macMiniKey ];
    # Nightly from master, so Docker, OpenSSH and the kernel keep up with the
    # weekly flake.lock bump without anyone switching by hand.
    autoUpgrade.enable = true;
  };
  # The repo is public, so the host needs no credentials to fetch it.
  system.autoUpgrade.flake = "github:Justin-Arnold/nixconfig/master#cglt-previews";

  home-manager.users = lib.mkForce { };

  ############################################################
  ## Users and secrets (SOPS, host-scoped key)
  ############################################################
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

  sops = {
    defaultSopsFile = ../../secrets/hosts/cglt-previews.yaml;
    # Installed by `nix run .#install` / `.#provision` with HOST_AGE_KEY_FILE.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];

    secrets."root/console-password-hash".neededForUsers = true;
  };

  # The deploy key's public half (deploy.nix). Until it's here nothing can
  # deploy (docs/cglt-previews/REFERENCE.md, "The deploy key").
  cgltPreviews.deploy.authorizedKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINVDVwKwSzX26jrK5mnmBcSZ0htGi6oIy8hifpf6CZoj cglt-previews-deploy"];

  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
    # The pool's free space, next to the root disk's.
    extraEnvironment.EXTRA_FILESYSTEMS = "${root}__tank";
  };

  ############################################################
  ## ZFS
  ############################################################
  boot.supportedFilesystems.zfs = true;
  # Root is ext4; only `tank` is ZFS, imported by name at boot.
  boot.zfs.forceImportRoot = false;
  boot.zfs.extraPools = [ "tank" ];
  networking.hostId = "82596a6c";
  # The ARC would otherwise take half the RAM, which the previews need.
  boot.kernelParams = [ "zfs.zfs_arc_max=${toString (6 * 1024 * 1024 * 1024)}" ];
  services.zfs.autoScrub = {
    enable = true;
    pools = [ "tank" ];
  };

  # tank/previews and its two children, made once and left alone after.
  # Deploy jobs make everything below golden/ and live/ (`sudo zfs ...`).
  # config/ and stacks/ are plain directories in tank/previews, made here
  # rather than by tmpfiles, which runs before the pool's first datasets exist.
  systemd.services.preview-datasets = {
    description = "Create the preview datasets and directories";
    wantedBy = [ "multi-user.target" ];
    requires = [ "zfs-mount.service" ];
    after = [ "zfs-mount.service" ];
    before = [ "docker.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      ensure() {
        local ds=$1; shift
        if ! ${zfs} list -H -o name "$ds" >/dev/null 2>&1; then
          echo "creating $ds"
          ${zfs} create "$@" "$ds"
        fi
      }
      ensure tank/previews -o mountpoint=${root}
      ensure tank/previews/golden
      ensure tank/previews/live
      ${zfs} mount -a
      for ds in tank/previews tank/previews/golden tank/previews/live; do
        if [[ $(${zfs} get -H -o value mounted "$ds") != yes ]]; then
          echo "$ds isn't mounted" >&2
          exit 1
        fi
      done
      for dir in config stacks; do
        install -d -m 0755 -o ${facts.deployUser} -g ${facts.deployUser} ${root}/$dir
      done
    '';
  };

  ############################################################
  ## Docker
  ############################################################
  roles.docker = {
    enable = true;
    users = [ config.systemProfile.username facts.deployUser ];
    # Hawser reads dockhand/hawser.env from the shared secrets file, which
    # this host's key can't open. Dockhand runs here instead (ops.nix).
    dockhandManaged.enable = false;
    daemonSettings = {
      # Size-capped, compressed; `docker logs` and Dockhand still read it.
      "log-driver" = "local";
      # 1024 /24 networks: two per preview, plus builds and the ops tools.
      "default-address-pools" = [ { base = "172.20.0.0/14"; size = 24; } ];
    };
  };

  # Previews bind-mount their database and files from ZFS, so Docker (and
  # every `restart: unless-stopped` container) waits for the pool. A pool that
  # didn't import leaves Docker down instead of starting MySQL on an empty
  # directory.
  systemd.services.docker = {
    requires = [ "zfs-mount.service" "preview-datasets.service" ];
    after = [ "zfs-mount.service" "preview-datasets.service" ];
  };

  ############################################################
  ## Firewall
  ############################################################
  networking.firewall.allowedTCPPorts = lib.mkForce [ ];
  networking.firewall.extraCommands = lib.concatStringsSep "\n" (inboundRules ++ hostEgressRules ++ dockerUserRules);

  ############################################################
  ## Guards
  ############################################################
  # The exposure policy. .#checks.<system>.cglt-previews-exposure-guards breaks
  # each of these and fails unless evaluation refuses it.
  assertions = [
    {
      assertion = fw.allowedTCPPorts == [ ] && fw.allowedUDPPorts == [ ]
        && fw.allowedTCPPortRanges == [ ] && fw.allowedUDPPortRanges == [ ];
      message = "cglt-previews: no ports open to everyone; SSH, port 80 and the deploy port are opened per source in extraCommands (got TCP ${toString fw.allowedTCPPorts}, UDP ${toString fw.allowedUDPPorts}).";
    }
    {
      assertion = interfaceRules == { } && trustedInterfaces == [ ];
      message = "cglt-previews: no per-interface firewall openings or trusted interfaces (got ${toString (lib.attrNames interfaceRules ++ trustedInterfaces)}).";
    }
    {
      # Any other accept in extraCommands is a new opening.
      assertion = lib.sort lib.lessThan (lib.filter (lib.hasInfix "nixos-fw-accept") extraLines) == lib.sort lib.lessThan inboundRules;
      message = "cglt-previews: the firewall accepts SSH from ${toString facts.adminSources} and ports 80 and ${toString facts.deployPort} from the Newt (${facts.newt}), nothing else.";
    }
    {
      assertion = lib.all (rule: lib.elem rule extraLines) (hostEgressRules ++ dockerUserRules);
      message = "cglt-previews: the egress rules (preview-egress in OUTPUT, DOCKER-USER) must stay in networking.firewall.extraCommands; deploy jobs are root here and must not reach the lab.";
    }
    {
      assertion = !config.networking.nftables.enable;
      message = "cglt-previews: the firewall stays on iptables, the same backend Docker writes DOCKER-USER with.";
    }
    {
      assertion = !config.roles.docker.dockhandManaged.enable;
      message = "cglt-previews: no Hawser agent; it needs the shared secrets file and would expose the Docker API on port 2376.";
    }
    {
      assertion = lib.all (unit: lib.elem unit config.systemd.services.docker.requires && lib.elem unit config.systemd.services.docker.after)
        [ "zfs-mount.service" "preview-datasets.service" ];
      message = "cglt-previews: docker.service requires and comes after zfs-mount.service and preview-datasets.service, so no preview starts on an unmounted dataset.";
    }
    {
      assertion = config.system.autoUpgrade.enable && config.system.autoUpgrade.flake != null;
      message = "cglt-previews: the nightly upgrade from the flake keeps Docker, OpenSSH and the kernel current.";
    }
    {
      assertion = !config.sops.validateSopsFiles || builtins.pathExists config.sops.defaultSopsFile;
      message = ''
        cglt-previews: secrets/hosts/cglt-previews.yaml doesn't exist yet. Generate
        the host age key, add its recipient to .sops.yaml, create the file with
        sops and `git add` it (docs/cglt-previews/REFERENCE.md, "Secrets").
      '';
    }
  ];
}
