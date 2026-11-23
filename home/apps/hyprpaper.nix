{ lib, pkgs, ... }:

let
  # The monitors, by description, as Hyprland's config names them
  # (home/dotfiles/hyprland/data/displays.lua).
  displays = {
    left = "desc:LG Electronics LG SDQHD 301NTTQ2C937";
    center = "desc:LG Electronics LG ULTRAWIDE 404NTAB6S472";
    right = "desc:LG Electronics LG SDQHD 303NTSUCB374";
  };

  # Gneiss wallpapers, each drawn at every monitor's native size: 3440x1440
  # in the center, 2560x2880 on either side. The first is the default, and
  # Super + F11 swaps to the next (home/dotfiles/hyprland/config/utilities.lua).
  designs = [ "foliation" "contours" ];
  default = builtins.head designs;
  images = design: {
    left = ../wallpapers/gneiss-${design}-2560x2880-left.png;
    center = ../wallpapers/gneiss-${design}-3440x1440.png;
    right = ../wallpapers/gneiss-${design}-2560x2880-right.png;
  };

  # Sets one design on each monitor through hyprpaper's IPC. A monitor that
  # isn't connected is skipped.
  setDesign = design: lib.concatStringsSep "\n" (lib.mapAttrsToList
    (display: desc:
      "hyprctl hyprpaper wallpaper ${lib.escapeShellArg "${desc},${(images design).${display}}"} >/dev/null || true")
    displays);

  # gneiss-wallpaper [next | restore | <design>]. It remembers the design it
  # sets, and `restore` puts that back when hyprpaper starts on the default.
  switcher = pkgs.writeShellApplication {
    name = "gneiss-wallpaper";
    text = ''
      designs=(${lib.escapeShellArgs designs})
      state="''${XDG_STATE_HOME:-$HOME/.local/state}/gneiss-wallpaper"
      current="$(cat "$state" 2>/dev/null || echo ${default})"

      apply() {
        case "$1" in
      ${lib.concatMapStrings (design: ''
          ${design})
      ${setDesign design}
            ;;
      '') designs}
          *)
            echo "gneiss-wallpaper: no design named $1 (designs: ''${designs[*]})" >&2
            exit 64
            ;;
        esac
        mkdir -p "$(dirname "$state")"
        printf '%s\n' "$1" > "$state"
      }

      case "''${1:-next}" in
        next)
          next="${default}"
          for i in "''${!designs[@]}"; do
            if [ "''${designs[$i]}" = "$current" ]; then
              next="''${designs[(i + 1) % ''${#designs[@]}]}"
            fi
          done
          apply "$next"
          ;;
        restore)
          if [ "$current" != "${default}" ]; then
            for _ in $(seq 50); do
              if hyprctl hyprpaper listactive >/dev/null 2>&1; then
                apply "$current"
                break
              fi
              sleep 0.1
            done
          fi
          ;;
        *)
          apply "$1"
          ;;
      esac
    '';
  };
in {
  home.packages = [
    pkgs.hyprpaper
    switcher
  ];

  services.hyprpaper = {
    enable = true;
    settings.wallpaper =
      lib.mapAttrsToList
        (display: desc: {
          monitor = desc;
          path = "${(images default).${display}}";
        })
        displays
      # Any other monitor gets the default's center image.
      ++ [
        {
          monitor = "*";
          path = "${(images default).center}";
        }
      ];
  };

  # hyprpaper starts on the default design; put back the one picked last.
  # The leading "-" keeps a failure here from failing hyprpaper.
  systemd.user.services.hyprpaper.Service.ExecStartPost = "-${lib.getExe switcher} restore";
}
