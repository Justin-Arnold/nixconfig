{ config, pkgs, ... }:
let
  # Every Hyprland bind with a description, searchable by what it does.
  # Bound to Super + / (config/hotkeys.lua) and listed in the launcher as
  # "Hotkeys". hyprctl comes from the session, to match the running Hyprland.
  hotkeys = pkgs.writeShellApplication {
    name = "hypr-hotkeys";
    runtimeInputs = [ pkgs.jq config.programs.vicinae.package ];
    text = ''
      rows="$(hyprctl binds -j | jq -r '
        def mods: .modmask as $m
          | [[64, "Super"], [4, "Ctrl"], [1, "Shift"], [8, "Alt"]]
          | map(select(($m / .[0] | floor) % 2 == 1) | .[1]);
        def key: {"slash": "/", "grave": "`", "Return": "Enter", "Escape": "Esc"}[.key] // .key;
        .[]
        | select(.has_description)
        # hyprshell adds release binds on the modifiers to close its switcher.
        | select(.description | startswith("hyprshell-keybind: Close") | not)
        | (.description
            | sub("^hyprshell-keybind: "; "") | sub(" with .*$"; "") | sub("Switch"; "window switcher")
          ) as $what
        | "\($what)  —  \(mods + [key] | join(" + "))"
      ' | sort -u)"

      printf '%s\n' "$rows" | vicinae dmenu \
        --navigation-title Hotkeys \
        --placeholder "Search hotkeys by what they do" \
        --section-title "{count} hotkeys" \
        --no-quick-look >/dev/null || true
    '';
  };
in
{
  xdg.desktopEntries.hypr-hotkeys = {
    name = "Hotkeys";
    genericName = "Keyboard shortcuts";
    comment = "Search Hyprland hotkeys by what they do";
    exec = "${hotkeys}/bin/hypr-hotkeys";
    icon = "input-keyboard";
    terminal = false;
    categories = [ "Utility" ];
    settings.Keywords = "keybinds;shortcuts;keys;hyprland;";
  };

  home.packages = [
    hotkeys
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
          for name in aichat codex terminal; do
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

  programs.vicinae = {
    enable = true;
    systemd.enable = true;
    mutableSettings = true;
    enableFirefoxIntegration = false;
    settings = {
      close_on_focus_loss = true;
      pop_to_root_on_close = true;
      search_files_in_root = false;
      # Hyprland handles Meta+Space through vicinae toggle.
      global_shortcuts.toggle = "";
      launcher_window.layer_shell.enabled = true;
    };
  };

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
