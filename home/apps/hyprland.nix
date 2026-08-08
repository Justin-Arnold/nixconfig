{ pkgs, ... }: {
  home.packages = [
    (pkgs.writeShellApplication {
      name = "hypr-popout";
      runtimeInputs = [
        pkgs.alacritty
        pkgs.gnugrep
        pkgs.gnused
        pkgs.hyprland
      ];
      text = ''
        set -euo pipefail

        popout_name="''${2:-}"
        popout_class=""
        popout_workspace=""
        popout_command=""

        resolve_popout() {
          case "$1" in
            aichat)
              popout_class="aichat-popup"
              popout_workspace="aichat-popout"
              popout_command="alacritty --class aichat-popup -e aichat"
              ;;
            oterm)
              popout_class="oterm-popup"
              popout_workspace="oterm-popout"
              popout_command="alacritty --class oterm-popup -e oterm"
              ;;
            codex)
              popout_class="codex-popup"
              popout_workspace="codex-popout"
              popout_command="alacritty --class codex-popup -e codex"
              ;;
            terminal)
              popout_class="terminal-popup"
              popout_workspace="terminal-popout"
              popout_command="alacritty --class terminal-popup"
              ;;
            *)
              echo "unknown popout: $1" >&2
              exit 64
              ;;
          esac
        }

        client_exists() {
          hyprctl clients | grep -Fq "class: $popout_class"
        }

        active_workspace() {
          hyprctl activeworkspace -j | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'
        }

        start_popout() {
          if ! client_exists; then
            hyprctl dispatch exec "[workspace special:$popout_workspace silent] $popout_command" >/dev/null
          fi
        }

        toggle_popout() {
          if client_exists; then
            hyprctl dispatch togglespecialworkspace "$popout_workspace" >/dev/null
            return
          fi

          start_popout
          if [ "$(active_workspace)" != "special:$popout_workspace" ]; then
            hyprctl dispatch togglespecialworkspace "$popout_workspace" >/dev/null
          fi
        }

        close_active() {
          active_class="$(hyprctl activewindow | sed -n 's/^[[:space:]]*class: //p')"
          case "$active_class" in
            aichat-popup)
              hyprctl dispatch togglespecialworkspace aichat-popout >/dev/null
              ;;
            oterm-popup)
              hyprctl dispatch togglespecialworkspace oterm-popout >/dev/null
              ;;
            codex-popup)
              hyprctl dispatch togglespecialworkspace codex-popout >/dev/null
              ;;
            terminal-popup)
              hyprctl dispatch togglespecialworkspace terminal-popout >/dev/null
              ;;
            *)
              hyprctl dispatch killactive >/dev/null
              ;;
          esac
        }

        start_all() {
          for name in aichat oterm codex terminal; do
            resolve_popout "$name"
            start_popout
          done
        }

        case "''${1:-}" in
          start)
            if [ "$popout_name" = "all" ]; then
              start_all
            else
              resolve_popout "$popout_name"
              start_popout
            fi
            ;;
          toggle)
            resolve_popout "$popout_name"
            toggle_popout
            ;;
          close-active)
            close_active
            ;;
          *)
            echo "usage: hypr-popout {start <name|all>|toggle <name>|close-active}" >&2
            exit 64
            ;;
        esac
      '';
    })
  ];

  wayland.windowManager.hyprland = {
    enable = true;

    package = null;
    portalPackage = null;
    configType = "lua";
    systemd.enable = false;

    extraConfig = ''
      hl.plugin.load("${pkgs.hyprlandPlugins.hy3}/lib/libhy3.so")


      local config_home =
        os.getenv("XDG_CONFIG_HOME")
        or (os.getenv("HOME") .. "/.config")

      package.path =
        config_home .. "/hypr/?.lua;"
        .. config_home .. "/hypr/?/init.lua;"
        .. package.path

      require("hyprland.init")
    '';
  };

  xdg.configFile = {
    "hypr/hyprland" = {
      source = ../dotfiles/hyprland;
      recursive = true;
    };
  };
}
