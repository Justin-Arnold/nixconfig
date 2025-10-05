{ pkgs, lib, config, ... }:

let cfg = config.modules.apps.godot;
in {
  options.modules.apps.godot = {
    enable = lib.mkEnableOption "open source 2D and 3D game engine";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.godot ];
  };
}

