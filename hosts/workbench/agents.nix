# The agents that work on this host, and what they work with.
#
# Each Hermes instance with an ssh terminal logs in from the agents VM as
# agent-<name>. Its key works only from that VM and allows no forwarding, pty
# or ~/.ssh/rc, and sshd says the same for every agent-* user. Commands run as
# that user: a home only it can read, no sudo, rootless Podman, and the same
# egress filter as on agents (the Internet, nothing in the LAN). Nix's build
# users are filtered too, since they fetch sources for the agents' builds.
#
# On GitHub the agents push as one machine account with a classic token,
# repo scope only. Fine-grained tokens can't act on repos where the account
# is only a collaborator, and without the workflow scope GitHub refuses any
# push that touches .github/workflows. Rulesets on the repos keep every
# branch except agent/** out of its reach. The token is readable by the
# agents group, through git's credential helper and the gh wrapper.
{ config, lib, pkgs, ... }:
let
  cfg = config.workbench;
  agentsVm = "10.0.0.152";

  userOf = name: "agent-${name}";
  homeOf = name: "/home/${userOf name}";
  names = lib.attrNames cfg.agents;
  github = cfg.github;
  tokenPath = config.sops.secrets."github/token".path;

  credentialHelper = pkgs.writeShellScript "git-credential-github-token" ''
    # git asks with "get"; anything else (store, erase) is a no-op.
    [ "$1" = get ] || exit 0
    cat >/dev/null
    printf 'username=%s\npassword=%s\n' ${lib.escapeShellArg github.login} "$(cat ${tokenPath})"
  '';

  gh = pkgs.writeShellScriptBin "gh" ''
    export GH_TOKEN GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1
    GH_TOKEN=$(cat ${tokenPath})
    exec ${lib.getExe pkgs.gh} "$@"
  '';

  inherit (import ./scripts.nix { inherit pkgs; }) agentWorktree agentReview pruneWorktrees;
in
{
  options.workbench = {
    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          uid = lib.mkOption {
            type = lib.types.int;
            description = "uid and gid of agent-<name>.";
          };
          publicKey = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              The public half of hermes/<name>/ssh-key in
              secrets/hosts/agents.yaml. Until it's set the user exists but
              can't log in.
            '';
          };
        };
      });
      default = { };
      description = "Agents that log in here, by their name on the agents VM.";
    };

    github = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          login = lib.mkOption { type = lib.types.str; };
          email = lib.mkOption {
            type = lib.types.str;
            description = "The account's noreply address, <id>+<login>@users.noreply.github.com.";
          };
        };
      });
      default = null;
      description = ''
        The machine account the agents push as. Its token goes in
        secrets/hosts/workbench.yaml as github/token. Until it's set, agents
        can only clone public repos.
      '';
    };
  };

  config = {
    # uids mirror the Hermes instances' (3202 there, 3302 here).
    workbench.agents = {
      engineer = { uid = 3302; publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOc8FUXO9eZx+gHjhspUd9TkuQjY6EmV6hQO8PtdszlQ hermes-engineer@agents"; };
      reviewer = { uid = 3304; publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIsKmq7E0NybXkmvaJitV2vUqY+aySmkVnYd1tL3+QJS hermes-reviewer@agents"; };
      infra = { uid = 3305; publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII6+doCJGGnlBkECECWRuJ5o0WDMM2cPbN9Dp7BGfvF8 hermes-infra@agents"; };
    };
    workbench.github = {
      login = "flickering-text-387";
      email = "351970363+flickering-text-387@users.noreply.github.com";
    };

    warnings =
      lib.optional (github == null)
        "workbench: no GitHub machine account yet (workbench.github in hosts/workbench/agents.nix), so agents can't push."
      ++ map (name: "workbench: agent-${name} has no ssh key yet, so it can't log in.")
        (lib.filter (name: cfg.agents.${name}.publicKey == null) names);

    users.groups = { agents.gid = 3300; }
      // lib.mapAttrs' (name: a: lib.nameValuePair (userOf name) { gid = a.uid; }) cfg.agents;
    users.users = lib.mapAttrs' (name: a: lib.nameValuePair (userOf name) {
      isNormalUser = true;
      uid = a.uid;
      group = userOf name;
      extraGroups = [ "agents" ];
      # For rootless Podman.
      autoSubUidGidRange = true;
      openssh.authorizedKeys.keys = lib.optional (a.publicKey != null) ''restrict,from="${agentsVm}" ${a.publicKey}'';
    }) cfg.agents;

    # Hermes' terminal starts in ~/work; agent-worktree puts worktrees there.
    systemd.tmpfiles.rules = map (name: "d ${homeOf name}/work 0700 ${userOf name} ${userOf name} - -") names;

    services.openssh.settings.AllowUsers = [ config.systemProfile.username ] ++ map userOf names;
    services.openssh.extraConfig = ''
      Match User agent-*
        AllowAgentForwarding no
        AllowTcpForwarding no
        AllowStreamLocalForwarding no
        X11Forwarding no
        PermitTunnel no
        PermitTTY no
        PermitUserRC no
    '';

    roles.agentEgress = {
      enable = true;
      users = map userOf names;
      groups = [ "nixbld" ];
    };

    # Rootless only: no Docker-compatible socket, nothing running as root.
    virtualisation.podman.enable = true;
    # nixpkgs opens DNS (port 53) on every podman interface by default.
    # Podman here is rootless, so its networks never touch the host's
    # interfaces; it stays shut and workbench's firewall guard still holds.
    virtualisation.podman.dns.openFirewall = false;

    sops.secrets = lib.mkIf (github != null) {
      "github/token" = {
        group = "agents";
        mode = "0440";
      };
    };

    programs.git = {
      enable = true;
      config = {
        # `git push` sends a branch to the branch of the same name, made on
        # the first push.
        push = { default = "current"; autoSetupRemote = true; };
        init.defaultBranch = "main";
      } // lib.optionalAttrs (github != null) {
        user = { name = github.login; inherit (github) email; };
        credential."https://github.com".helper = "${credentialHelper}";
      };
    };

    environment.systemPackages = [ agentWorktree agentReview pkgs.gnumake pkgs.file pkgs.tree pkgs.unzip ]
      ++ lib.optional (github != null) gh;

    # Worktrees nobody touched for two weeks go, when everything in them is
    # committed and on GitHub.
    systemd.services.prune-worktrees = {
      description = "Remove the agents' finished worktrees";
      serviceConfig.Type = "oneshot";
      path = [ pkgs.util-linux ];
      script = lib.concatMapStringsSep "\n" (name: ''
        runuser -u ${userOf name} -- env HOME=${homeOf name} ${lib.getExe pruneWorktrees} ${homeOf name} 14
      '') names;
    };
    systemd.timers.prune-worktrees = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
