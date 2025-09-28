{ pkgs, lib, config, ... }:

let
  cfg = config.modules.apps.onepassword;
in
{
  options.modules.apps.onepassword = {
    enable = lib.mkEnableOption "1Password and 1Password GUI";
    
    polkit = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether to enable polkit integration for 1Password.
          Required for CLI integration and system authentication on some desktop environments.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    programs._1password.enable = true;
    
    programs._1password-gui = {
      enable = true;
      polkitPolicyOwners = lib.mkIf cfg.polkit.enable [ config.systemProfile.username ];
    };

    # Only enable polkit and related services if explicitly requested
    security.polkit.enable = lib.mkIf cfg.polkit.enable true;

    systemd.user.services.polkit-gnome-authentication-agent-1 = lib.mkIf cfg.polkit.enable {
      description = "polkit-gnome-authentication-agent-1";
      wantedBy = [ "graphical-session.target" ];
      wants = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
        Restart = "on-failure";
        RestartSec = 1;
        TimeoutStopSec = 10;
      };
    };
  };
}