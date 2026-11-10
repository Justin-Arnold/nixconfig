# How GitHub Actions reaches this host. The monorepo's preview workflows run
# on GitHub-hosted runners and come in over SSH, through a raw TCP resource on
# the Pangolin VPS and the home site's Newt:
#
#   VPS:<port> → Newt (10.0.0.72) → this VM:2222
#
# sshd listens on a second port, 2222, which the firewall opens to the Newt
# only. There it lets in preview-deploy and nobody else, by public key only,
# and runs preview-ctl (preview-ctl.nix) whatever the client asked for: no
# TTY, no TCP or socket forwarding, no X11. Agent forwarding stays on, because
# the snapshot jobs reach the source instances with the runner's agent.
# preview-deploy can't log in on port 22.
#
# Every connection on 2222 comes from the Newt's address, so there's no
# fail2ban or sshguard: one ban would lock every job out.
#
# preview-deploy is in the docker group, so whoever holds the deploy key is
# root here, as the runners' jobs were. It may also run exactly
# `sudo -n /run/current-system/sw/bin/zfs` and `zpool`. sshd runs in the
# host's mount namespace and without no_new_privs, so sudo works and a
# dataset a job mounts is visible to Docker. The guards here keep it that way.
{ config, lib, pkgs, ... }:
let
  facts = import ./facts.nix;
  cfg = config.cgltPreviews.deploy;
  user = facts.deployUser;
  home = "/var/lib/${user}";
  workRoot = "${home}/work";
  port = facts.deployPort;
  ssh = config.services.openssh;

  previewCtl = pkgs.callPackage ./preview-ctl.nix {
    inherit workRoot;
    # What host.sh gets on its PATH, plus sudo from /run/wrappers/bin. zfs and
    # zpool aren't on it: the scripts call them through sudo by full path.
    tools = with pkgs; [
      bash
      coreutils
      config.virtualisation.docker.package # with the compose and buildx plugins
      git
      jq
      yq-go
      curl
      rsync
      openssh
      gzip
      zstd
      util-linux # flock
      gnused
      gawk
      gnugrep
      findutils
      gnutar
    ];
  };

  # Appended to sshd_config last (Match blocks run to the end of the file).
  matchBlocks = ''
    # cglt-previews: port ${toString port} is the deploy entry (hosts/cglt-previews/deploy.nix).
    Match LocalPort ${toString port} User *,!${user}
      DenyUsers *
    Match LocalPort ${toString port}
      AuthenticationMethods publickey
      PubkeyAuthentication yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u
      ForceCommand ${lib.getExe previewCtl}
      PermitTTY no
      AllowTcpForwarding no
      AllowStreamLocalForwarding no
      PermitListen none
      PermitOpen none
      GatewayPorts no
      PermitTunnel no
      X11Forwarding no
      PermitUserRC no
      AllowAgentForwarding yes
      AcceptEnv PREVIEW_*
      ClientAliveInterval 30
      ClientAliveCountMax 4
      LogLevel VERBOSE
    Match LocalPort 22 User ${user}
      DenyUsers *
  '';

  # Options that give a service its own mount namespace. Mounts made inside
  # one don't propagate to the host (systemd.exec(5), PrivateMounts=).
  namespaced = sc:
    lib.filter (opt: sc ? ${opt} && sc.${opt} != false && sc.${opt} != [ ] && sc.${opt} != "")
      [ "PrivateMounts" "PrivateTmp" "PrivateDevices" "PrivateUsers" "ProtectSystem" "ProtectHome"
        "ProtectKernelTunables" "ProtectKernelModules" "ProtectKernelLogs" "ProtectControlGroups"
        "ReadWritePaths" "ReadOnlyPaths" "InaccessiblePaths" "BindPaths" "BindReadOnlyPaths"
        "TemporaryFileSystem" "MountImages" "RootDirectory" "RootImage" ]
    ++ lib.optional ((sc.ProtectProc or "default") != "default") "ProtectProc"
    ++ lib.optional ((sc.ProcSubset or "all") != "all") "ProcSubset";

  # Options that set no_new_privs, with which sudo refuses to run.
  noNewPrivs = sc:
    lib.filter (opt: sc ? ${opt} && sc.${opt} != false && sc.${opt} != [ ] && sc.${opt} != "")
      [ "NoNewPrivileges" "SystemCallFilter" "SystemCallArchitectures" "RestrictAddressFamilies"
        "RestrictNamespaces" "RestrictRealtime" "RestrictSUIDSGID" "MemoryDenyWriteExecute"
        "LockPersonality" "DynamicUser" "CapabilityBoundingSet" ];
  sshdService = (config.systemd.services.sshd or { serviceConfig = { }; }).serviceConfig;

  sudoRules = lib.filter (rule: lib.elem user (rule.users or [ ])) config.security.sudo.extraRules;
  # A command is a string or { command; options; }.
  sudoCommand = c: if builtins.isString c then { command = c; options = [ ]; } else { command = c.command or ""; options = c.options or [ ]; };
  zfsCommands = [ "/run/current-system/sw/bin/zfs" "/run/current-system/sw/bin/zpool" ];

  # Plain public keys; the options are added here.
  plainKey = key: builtins.match "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) [A-Za-z0-9+/]+=*( .*)?" key != null;
in
{
  options.cgltPreviews.deploy = {
    authorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.singleLineStr;
      default = [ ];
      example = [ "ssh-ed25519 AAAAC3Nza... cglt-previews-deploy" ];
      description = ''
        Public keys that may deploy, as plain `<type> <base64> [comment]`
        lines. Each is installed with `restrict,agent-forwarding` in front.
        The private halves live in the monorepo's GitHub secrets. While this
        is empty, nothing can deploy and the build prints a warning.
      '';
    };
  };

  config = lib.mkMerge [
    {
      users.groups.${user}.gid = facts.deployId;
      users.users.${user} = {
        isSystemUser = true;
        uid = facts.deployId;
        group = user;
        extraGroups = [ "docker" ];
        inherit home;
        createHome = true;
        # sshd runs the forced command through the login shell.
        shell = pkgs.bashInteractive;
        description = "CGLT preview deploys over SSH";
        openssh.authorizedKeys.keys = map (key: "restrict,agent-forwarding ${key}") cfg.authorizedKeys;
      };

      # Exactly these two, with any arguments. The monorepo's scripts call them
      # by these paths.
      security.sudo.extraRules = [
        {
          users = [ user ];
          commands = map (command: { inherit command; options = [ "NOPASSWD" ]; }) zfsCommands;
        }
      ];

      # On the root disk. A job's directory is removed when it ends; whatever
      # that can't remove (root-owned files a container left) goes after a day.
      systemd.tmpfiles.rules = [ "d ${workRoot} 0750 ${user} ${user} 1d" ];

      services.openssh.ports = [ 22 port ];
      services.openssh.extraConfig = lib.mkAfter matchBlocks;

      assertions = [
        {
          assertion = map (rule: map sudoCommand (rule.commands or [ ])) sudoRules
              == [ (map (command: { inherit command; options = [ "NOPASSWD" ]; }) zfsCommands) ]
            && lib.all (rule: (rule.groups or [ ]) == [ ]) sudoRules
            && !(lib.elem user (config.users.groups.wheel.members or [ ]))
            && !(lib.elem "wheel" config.users.users.${user}.extraGroups);
          message = "cglt-previews: ${user} may run ${toString zfsCommands} through sudo and nothing else, and isn't in wheel.";
        }
        {
          assertion = !(lib.elem user config.nix.settings.trusted-users) && !(lib.elem "*" config.nix.settings.trusted-users);
          message = "cglt-previews: ${user} isn't a trusted Nix user.";
        }
        {
          assertion = lib.sort lib.lessThan ssh.ports == [ 22 port ] && ssh.listenAddresses == [ ];
          message = "cglt-previews: sshd listens on 22 (admin) and ${toString port} (deploys), nothing else; the Match blocks only cover those two.";
        }
        {
          assertion = lib.hasSuffix matchBlocks ssh.extraConfig;
          message = "cglt-previews: the deploy Match blocks must end sshd_config; anything after them would apply to deploys only.";
        }
        {
          assertion = lib.all plainKey cfg.authorizedKeys;
          message = "cglt-previews: cgltPreviews.deploy.authorizedKeys takes plain public keys, without options; deploy.nix adds them.";
        }
        {
          assertion = !ssh.startWhenNeeded && namespaced sshdService == [ ] && noNewPrivs sshdService == [ ];
          message = "cglt-previews: sshd runs as a plain service in the host's mount namespace, without no_new_privs, or deploys can't `sudo zfs` or their mounts never reach Docker (got ${toString (namespaced sshdService ++ noNewPrivs sshdService)}).";
        }
        {
          assertion = !(lib.hasSuffix "nologin" (toString config.users.users.${user}.shell));
          message = "cglt-previews: ${user} needs a real shell; sshd runs the forced command through it.";
        }
        {
          assertion = !config.services.fail2ban.enable && !config.services.sshguard.enable;
          message = "cglt-previews: no fail2ban or sshguard; every deploy connects from the Newt's address, and a ban would block them all.";
        }
      ];
    }

    (lib.mkIf (cfg.authorizedKeys == [ ]) {
      warnings = [
        "cglt-previews: cgltPreviews.deploy.authorizedKeys is empty, so nothing can deploy (docs/cglt-previews/REFERENCE.md, \"The deploy key\")."
      ];
    })
  ];
}
