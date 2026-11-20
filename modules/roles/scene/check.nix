# nix build .#checks.<system>.scene
{ pkgs }:
pkgs.runCommand "scene-tests"
  {
    # lua5_5 is the Lua that Hyprland embeds; the tests run the rule code
    # scene sends to Hyprland in it.
    nativeBuildInputs = [ pkgs.python3 pkgs.nix pkgs.lua5_5 ];
  }
  ''
    export SCENE_TEST_NIX_OUT=$PWD/exported.nix SCENE_TEST_NEEDS_LUA=1
    if ! python3 -I ${./test.py} ${./scene.py} >log 2>&1; then
      cat log
      exit 1
    fi
    cat log

    # What `scene export` prints has to be Nix, and a module body at that.
    export HOME=$PWD NIX_STATE_DIR=$PWD/nix/state NIX_STORE_DIR=$PWD/nix/store NIX_LOG_DIR=$PWD/nix/log
    nix-instantiate --eval --strict --option store dummy:// -E "import $PWD/exported.nix { }" >evaluated
    grep -q 'new-scene' evaluated
    grep -q 'position = \[ -300 -40 \]' evaluated

    cp log $out
  ''
