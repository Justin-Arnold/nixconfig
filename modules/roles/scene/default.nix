# modules/roles/scene/default.nix
#
# Scenes: named sets of apps on their workspaces, for Hyprland.
#
#   scene open work      start the apps of a scene that are not running and
#                        put their windows on their workspaces
#   scene save           snapshot the open apps as the scene "last"
#   scene restore        reopen that snapshot, e.g. after logging back in
#   scene export --copy  copy the current layout as Nix, to declare it here
#
# A scene declared here is a preset, under roles.scene.presets; one saved at
# run time is a snapshot. Every .nix file in ./presets is imported, so a
# preset is added by dropping a file there. Each preset, and save, restore and
# export, gets a launcher entry ("Scene: …") and a keybind if it has a key.
# Results are reported as desktop notifications.
#
# Apps are named by desktop entry, not by command, so a scene survives
# updates. A window is placed by a short-lived Hyprland rule set just before
# its app starts, so it opens where it belongs, splash screens included.
# scene.py documents the scene format and the tool's limits; it reads
# everything from /etc/xdg/scene and knows nothing about this repository.
{ config, lib, pkgs, ... }:
let
  cfg = config.roles.scene;

  presetFiles = builtins.filter (name: lib.hasSuffix ".nix" name)
    (builtins.attrNames (builtins.readDir ./presets));

  pair = lib.types.addCheck (lib.types.listOf lib.types.int) (l: builtins.length l == 2);

  windowType = lib.types.submodule {
    options = {
      app = lib.mkOption {
        type = lib.types.str;
        example = "discord";
        description = "Desktop entry ID of the app: its .desktop file name without the suffix.";
      };
      workspace = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "4";
        description = "Workspace the window goes to. Unset leaves it where it opens.";
      };
      floating = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to float the window.";
      };
      size = lib.mkOption {
        type = lib.types.nullOr pair;
        default = null;
        example = [ 1200 800 ];
        description = "Width and height of a floating window.";
      };
      position = lib.mkOption {
        type = lib.types.nullOr pair;
        default = null;
        example = [ 100 100 ];
        description = "Position of a floating window, in the coordinates of the whole monitor layout.";
      };
      class = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Window class, for a window whose class does not lead back to the desktop entry.";
      };
      command = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Shell command that starts the app, for an app with no desktop entry.";
      };
    };
  };

  sceneType = lib.types.submodule {
    options = {
      key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "SUPER + ALT + W";
        description = "Hyprland key combination that opens the scene.";
      };
      windows = lib.mkOption {
        type = lib.types.listOf windowType;
        description = "The apps of the scene, in the order they are opened.";
      };
    };
  };

  keyOption = default: action: lib.mkOption {
    type = lib.types.nullOr lib.types.str;
    inherit default;
    description = "Hyprland key combination that ${action}. null leaves it unbound.";
  };

  # Unset fields stay out of the files.
  sceneJson = scene: builtins.toJSON {
    inherit (scene) key;
    windows = map (lib.filterAttrs (_: value: value != null && value != false)) scene.windows;
  };

  sceneFile = name: scene: pkgs.writeText "${name}.json" (sceneJson scene);

  configFile = pkgs.writeText "scene-config.json" (builtins.toJSON {
    inherit (cfg) keys timeout;
    rule_seconds = cfg.ruleSeconds;
    nix_attr = "roles.scene.presets";
    program = "scene";
  });

  scene = pkgs.writeShellScriptBin "scene" ''
    # Appended, so tools of the session itself win. hyprctl and uwsm always
    # come from the session: they have to match what is running.
    PATH="$PATH:${lib.makeBinPath [ pkgs.wl-clipboard pkgs.libnotify ]}"
    export PATH
    exec ${pkgs.python3}/bin/python3 -I ${./scene.py} "$@"
  '';

  # The keybinds and launcher entries, written by the tool from the same
  # files it reads at run time.
  generated = pkgs.runCommand "scene-generated" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p config/scene/presets $out/share/applications
    cp ${configFile} config/scene/config.json
    ${lib.concatStrings (lib.mapAttrsToList (name: s: ''
      cp ${sceneFile name s} config/scene/presets/${name}.json
    '') cfg.presets)}
    export XDG_CONFIG_HOME=$PWD/none XDG_CONFIG_DIRS=$PWD/config XDG_STATE_HOME=$PWD/state
    python3 -I ${./scene.py} binds > $out/hyprland.lua
    python3 -I ${./scene.py} desktop-entries --out $out/share/applications
  '';
in
{
  imports = map (f: ./presets + "/${f}") presetFiles;

  options.roles.scene = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.modules.roles.nixos.desktopEnvironments.hyprland.enable;
      defaultText = lib.literalExpression "config.modules.roles.nixos.desktopEnvironments.hyprland.enable";
      description = "Whether to install scene and its keybinds and launcher entries.";
    };

    presets = lib.mkOption {
      type = lib.types.attrsOf sceneType;
      default = { };
      description = "Scenes declared in this configuration, by name.";
    };

    keys = {
      save = keyOption "SUPER + ALT + S" "saves a snapshot";
      restore = keyOption "SUPER + ALT + R" "reopens the last snapshot";
      export = keyOption "SUPER + ALT + N" "copies the current layout as a Nix scene";
    };

    timeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = "Seconds to wait for the window of an app that was just started.";
    };

    ruleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        How long after an app is started its new windows are still sent to
        its workspace. It has to outlast a splash or updater window; until it
        ends, a window of that app you open yourself goes there too.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (name: _: {
      assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;
      message = "roles.scene.presets.\"${name}\": a scene name may only have letters, digits, '.', '_' and '-'.";
    }) cfg.presets;

    environment.systemPackages = [ scene generated ];

    environment.etc = {
      "xdg/scene/config.json".source = configFile;
      # Loaded by home/dotfiles/hyprland/config/scenes.lua.
      "xdg/scene/hyprland.lua".source = "${generated}/hyprland.lua";
    } // lib.mapAttrs' (name: s:
      lib.nameValuePair "xdg/scene/presets/${name}.json" { source = sceneFile name s; }
    ) cfg.presets;
  };
}
