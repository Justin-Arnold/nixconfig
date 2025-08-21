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
{ config, pkgs, lib, ... }:
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
          user = config.hostSpec.username;
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
    stateVersion = lib.mkOption {
      type = lib.types.str;
      description = "The NixOS state version, indicating the system's configuration version.";
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
  };
}