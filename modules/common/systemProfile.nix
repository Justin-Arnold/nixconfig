# Host Profile Module
#
# This module defines shared configuration options that describe the fundamental
# characteristics and capabilities of each host in the system. These options are
# used throughout the configuration to conditionally enable features, set paths,
# and customize behavior based on the host's role and environment.
#
# Defines options such as:
# - Basic host identity (username, hostname, paths)
# - Host capabilities and roles (isServer, isGui, etc.)
# - Environment-specific settings and flags
#
# These options are intended to be set once per host and referenced by other
# modules to make configuration decisions, promoting consistency and reducing
# duplication across the system configuration.
{ config, pkgs, lib, inputs, ... }:
let
  palettes = import ./themes { inherit lib; inherit (inputs) gneiss; };
in
{
  options.systemProfile = {
    ############################################################
    ## Data Variables
    ############################################################
    username = lib.mkOption {
      type = lib.types.str;
      description = "The primary username for the system.";
      default = "justin";
    };
    hostname = lib.mkOption {
      type = lib.types.str;
      description = "The hostname of the system.";
    };
    email = lib.mkOption {
      type = lib.types.str;
      description = "The email address associated with the primary user.";
      default = "hello@justin-arnold.com";
    };
    homeDirectory = lib.mkOption {
      type = lib.types.str;
      description = "The home directory path for the primary user.";
      default =
        let
          user = config.systemProfile.username;
        in
          if pkgs.stdenv.hostPlatform.isDarwin
          then "/Users/${user}"
          else "/home/${user}";
    };
    timeZone = lib.mkOption {
      type = lib.types.str;
      description = "The system time zone.";
      default = "America/New_York";
    };
    fonts.primary = lib.mkOption {
      type = lib.types.submodule {
        options = {
          family = lib.mkOption {
            type = lib.types.str;
            description = "Font family name used by applications that follow the system profile.";
          };
          package = lib.mkOption {
            type = lib.types.package;
            description = "Package that provides the primary font family.";
          };
        };
      };
      description = "Primary font for desktop applications.";
      default = {
        # Hasklug is the Nerd Font build of Hasklig, which adds ligatures to Source Code Pro.
        family = "Hasklug Nerd Font";
        package = pkgs.nerd-fonts.hasklug;
      };
    };
    theme = lib.mkOption {
      # One per palette in ./themes.
      type = lib.types.enum (builtins.attrNames palettes);
      description = ''
        Color theme for applications that follow the system profile. Each app
        maps it to its own port of that theme (docs/theming/REFERENCE.md).
      '';
      default = "gneiss";
    };
    palette = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        The theme's colors by role, from themes/<theme>.toml, for apps that
        are themed here from raw colors rather than by their own port.
      '';
      default = palettes.${config.systemProfile.theme};
      defaultText = lib.literalMD "the colors in `themes/<theme>.toml`";
    };
    stateVersion = lib.mkOption {
      type = lib.types.str;
      description = "The NixOS state version, indicating the system's configuration version.";
    };
    stateVersionDarwin = lib.mkOption {
      type = lib.types.int;
      description = "The nix-darwin state version, indicating the system's configuration version.";
    };
    ############################################################
    ## Configuration Flags
    ############################################################
    hasGui = lib.mkOption {
      type = lib.types.bool;
      description = "Indicates if the system has a graphical user interface (GUI).";
      default = false;
    };
    forCglt = lib.mkOption {
      type = lib.types.bool;
      description = "Indicates if the system is used for CGLT work.";
      default = false;
    };
    isServer = lib.mkOption {
      type = lib.types.bool;
      description = "Indicates if the system is a server or vm.";
      default = false;
    };
    isDarwin = lib.mkOption {
      type = lib.types.bool;
      description = "Indicates if the system is running macOS.";
      default = false;
    };
    isNixos = lib.mkOption {
      type = lib.types.bool;
      description = "Indicates if the system is running NixOS.";
      default = false;
    };
  };
}
