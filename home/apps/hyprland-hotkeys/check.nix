# nix build .#checks.<system>.hyprland-hotkeys
{ pkgs }:
pkgs.runCommand "hyprland-hotkeys-tests"
  {
    # lua5_5 is the Lua that Hyprland embeds.
    nativeBuildInputs = [ pkgs.lua5_5 ];
  }
  ''
    mkdir -p config
    cp -r ${../../dotfiles/hyprland} config/hyprland
    if ! lua ${./test.lua} "$PWD/config" >log 2>&1; then
      cat log
      exit 1
    fi
    cat log
    cp log $out
  ''
