# modules/roles/doppler-secrets.nix
#
# Materializes a Doppler config into restricted runtime files under /run.
#
# - Boot never depends on Doppler once seeded: doppler-secrets.service renders
#   from an age-encrypted last-known-good cache in /var/lib/doppler-secrets
#   (encrypted to the host age key and any extra recipients).
# - doppler-secrets-refresh (timer) fetches, validates the complete set, and
#   only then replaces the cache and restarts the services whose files changed.
#
# Doppler's own --fallback is deliberately not used: it is rewritten after
# every successful fetch without validation, and its default passphrase is the
# service token, so rotating the token would orphan it.
{ config, lib, pkgs, ... }:
let
  cfg = config.roles.dopplerSecrets;
  dopplerLib = import ./doppler-secrets/lib.nix { inherit pkgs lib; };

  outputType = lib.types.submodule ({ name, ... }: {
    options = {
      path = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "File path relative to the runtime directory.";
      };
      format = lib.mkOption {
        type = lib.types.enum [ "raw" "systemd-env" "docker-env" ];
        default = "raw";
        description = ''
          raw: the value of `key`, byte for byte (multi-line allowed).
          systemd-env: NAME='value' lines for systemd EnvironmentFile.
          docker-env: NAME=value lines for docker --env-file.
          Env formats reject values containing line breaks (and single quotes for systemd-env).
        '';
      };
      key = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Doppler key for raw outputs.";
      };
      vars = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Environment variable name -> Doppler key, for env outputs.";
      };
      static = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Non-secret variables written alongside, for env outputs.";
      };
      owner = lib.mkOption { type = lib.types.str; default = "root"; };
      group = lib.mkOption { type = lib.types.str; default = "root"; };
      mode = lib.mkOption { type = lib.types.str; default = "0400"; };
      restartServices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Services (without .service) to try-restart when this file changes.";
      };
    };
  });

  outputs = lib.attrValues cfg.outputs;
  services = lib.unique (lib.concatMap (o: o.restartServices) outputs);

  spec = dopplerLib.mkSpec {
    inherit outputs;
    inherit (cfg) validators;
    recipients = cfg.extraRecipients;
  };

  syncEnvironment = {
    DOPPLER_SECRETS_SPEC = "${spec}";
    DOPPLER_SECRETS_RUNTIME_DIR = cfg.runtimeDir;
    DOPPLER_SECRETS_STATE_DIR = cfg.stateDir;
    DOPPLER_SECRETS_AGE_IDENTITY = cfg.ageIdentityFile;
    DOPPLER_SECRETS_TOKEN_FILE = cfg.tokenFile;
    HOME = cfg.stateDir;
  };

  serviceConfig = {
    Type = "oneshot";
    RuntimeDirectory = lib.removePrefix "/run/" cfg.runtimeDir;
    RuntimeDirectoryMode = "0751";
    RuntimeDirectoryPreserve = "yes";
    StateDirectory = lib.removePrefix "/var/lib/" cfg.stateDir;
    StateDirectoryMode = "0700";
    UMask = "0077";
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
  };
in
{
  options.roles.dopplerSecrets = {
    enable = lib.mkEnableOption "Doppler-managed runtime secrets with an encrypted last-known-good cache";

    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "File containing a read-only Doppler service token (bootstrap secret, e.g. from sops-nix).";
    };

    ageIdentityFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sops-nix/key.txt";
      description = "Host age identity used to encrypt and decrypt the cache.";
    };

    extraRecipients = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional age recipients for the cache (e.g. the operator key, for recovery).";
    };

    runtimeDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/doppler-secrets";
      description = "tmpfs directory for rendered files. Must be under /run.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/doppler-secrets";
      description = "Persistent directory for the encrypted cache. Must be under /var/lib.";
    };

    refreshInterval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "How often to refresh from Doppler.";
    };

    validators = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Doppler key -> regex the value must match (jq/Oniguruma syntax).";
    };

    outputs = lib.mkOption {
      type = lib.types.attrsOf outputType;
      default = { };
      description = "Files to render.";
    };

    paths = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      default = lib.mapAttrs (_: o: "${cfg.runtimeDir}/${o.path}") cfg.outputs;
      description = "Absolute path of each output, for consumers.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.hasPrefix "/run/" cfg.runtimeDir && lib.hasPrefix "/var/lib/" cfg.stateDir;
        message = "roles.dopplerSecrets: runtimeDir must be under /run and stateDir under /var/lib.";
      }
    ] ++ lib.mapAttrsToList (name: o: {
      assertion = (o.format == "raw") == (o.key != null) && (o.format == "raw" -> o.vars == { } && o.static == { });
      message = "roles.dopplerSecrets.outputs.${name}: raw outputs need `key` only; env outputs need `vars`.";
    }) cfg.outputs ++ lib.mapAttrsToList (name: o: {
      assertion = lib.all (v: !(lib.hasInfix "'" v || lib.hasInfix "\n" v)) (lib.attrValues o.static);
      message = "roles.dopplerSecrets.outputs.${name}: static values must not contain quotes or newlines.";
    }) cfg.outputs;

    systemd.services = {
      doppler-secrets = {
        description = "Render Doppler-managed secrets (from the last-known-good cache when present)";
        wantedBy = [ "multi-user.target" ];
        before = map (s: "${s}.service") services;
        environment = syncEnvironment // {
          # Only used on first boot, when no cache exists yet.
          DOPPLER_SECRETS_FETCH_ATTEMPTS = "30";
        };
        serviceConfig = serviceConfig // {
          RemainAfterExit = true;
          ExecStart = "${dopplerLib.syncPackage}/bin/doppler-secrets-sync ensure";
        };
      };

      doppler-secrets-refresh = {
        description = "Refresh Doppler-managed secrets (keeps last-known-good on failure)";
        after = [ "doppler-secrets.service" "network-online.target" ];
        wants = [ "network-online.target" ];
        environment = syncEnvironment // {
          DOPPLER_SECRETS_FETCH_ATTEMPTS = "3";
        };
        serviceConfig = serviceConfig // {
          ExecStart = "${dopplerLib.syncPackage}/bin/doppler-secrets-sync refresh";
        };
      };
    } // lib.genAttrs services (_: {
      after = [ "doppler-secrets.service" ];
      wants = [ "doppler-secrets.service" ];
    });

    systemd.timers.doppler-secrets-refresh = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = cfg.refreshInterval;
        RandomizedDelaySec = "1min";
      };
    };

    environment.systemPackages = [ pkgs.doppler ];
  };
}
