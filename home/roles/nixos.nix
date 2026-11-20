{ config, inputs, lib, pkgs, osConfig, zen-browser, ... }:
let
  claudeDesktop = inputs.claude-desktop.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop;

  claudeUrlOpener = pkgs.writeShellScript "claude-open-web-url" ''
    export PATH="$PATH:${config.home.profileDirectory}/bin"
    export XDG_DATA_DIRS="''${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:${config.home.profileDirectory}/share"
    exec ${lib.getExe' pkgs.glib.bin "gio"} open "$1"
  '';

  # Claude resets PATH at startup, so its stock xdg-open cannot find Home
  # Manager browsers. Use an absolute opener for validated HTTP(S) links.
  browserCall = "u.shell.openExternal(i).catch(";
  browserCallWithGio = ''
    (/^https?:[/][/]/i.test(i)
      ? new Promise((resolve, reject) => process.getBuiltinModule("node:child_process").execFile(
          "${claudeUrlOpener}", [i], error => error ? reject(error) : resolve()))
      : u.shell.openExternal(i)).catch(
  '';
  patchBrowserCall = ''
    mapfile -t browserChunks < <(grep -rlF --include='*.js' ${lib.escapeShellArg browserCall} "$work/app/.vite/build")
    if [[ ''${#browserChunks[@]} -ne 1 ]]; then
      echo "Claude Desktop browser handoff changed upstream" >&2
      exit 1
    fi
    substituteInPlace "''${browserChunks[0]}" \
      --replace-fail ${lib.escapeShellArg browserCall} ${lib.escapeShellArg (lib.removeSuffix "\n" browserCallWithGio)}
    patched+=("''${browserChunks[0]}")
  '';
  # Use the package's existing ASAR repack and V8 cache invalidation.
  repackAnchor = ''for f in "''${patched[@]}"; do'';
in {
  imports = [
    ../apps/krusader.nix
    ../apps/hyprshell.nix
    ../apps/aichat.nix
    ../apps/codex.nix
  ];

  home.packages = [
    pkgs.luarocks
    pkgs.unzip
    (claudeDesktop.overrideAttrs (old: {
      postInstall =
        assert lib.assertMsg (lib.hasInfix repackAnchor old.postInstall)
          "Claude Desktop ASAR repack changed upstream";
        lib.replaceStrings [ repackAnchor ] [ (patchBrowserCall + repackAnchor) ] old.postInstall;
    }))
  ];

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = {
      ForwardAgent = false;
      AddKeysToAgent = "no";
      Compression = false;
      ServerAliveInterval = 0;
      ServerAliveCountMax = 3;
      HashKnownHosts = false;
      UserKnownHostsFile = "~/.ssh/known_hosts";
      ControlMaster = "no";
      ControlPath = "~/.ssh/master-%r@%n:%p";
      ControlPersist = "no";
      IdentityAgent = "~/.1password/agent.sock";
    };
  };

  #######################
  # Dark Theming
  #######################
  gtk = {
    enable = true;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    gtk3.extraConfig.gtk-application-prefer-dark-theme = 1;
    gtk4.extraConfig.gtk-application-prefer-dark-theme = 1;
  };

  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
  
  qt = {
    enable = true;
    style = {
      name = "adwaita-dark";
    };
  };
}
