{ pkgs, lib, config, ... }:

let cfg = config.modules.apps.zoxide;
in {
  options.modules.apps.zoxide = {
    enable = lib.mkEnableOption "Smart cd shell replacement";

    replaceCd = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Controls whether or not to replace the native CD command";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.zoxide ];

    programs.zsh.interactiveShellInit = ''
      eval "$(${pkgs.zoxide}/bin/zoxide init zsh ${
        lib.optionalString cfg.replaceCd "--cmd cd"
      })"
    '';
  };
}

