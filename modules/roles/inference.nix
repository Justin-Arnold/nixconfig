# llama.cpp's llama-server with one model loaded, for every client of the
# GPU: Home Assistant's voice assistant and the Mac. Clients ask for the
# model `local`; which model that is gets decided here, so changing it
# changes no client.
#
# The server only listens on loopback and has no network of its own; nginx
# (hosts/inference/endpoints.nix) is the way in. It runs `parallel` slots of
# `contextPerSlot` tokens each, with a q8_0 KV cache, and refuses to start
# rather than quietly shrink them (`--fit off`). Nothing a client sends is
# kept: no prompt logging, no slot files, no /slots or /props, no web UI, and
# no core dumps.
#
# Model files come from Hugging Face, pinned to a commit and checked against
# a sha256 by inference-models.service before the server starts. They stay in
# /var/lib/inference/models, outside the nix store, so a deploy never copies
# them.
{ config, lib, pkgs, ... }:
let
  cfg = config.roles.inference;
  modelsDir = "${cfg.stateDir}/models";
  active = cfg.models.${cfg.active}
    or (throw "roles.inference: active model ${cfg.active} isn't in models (${toString (lib.attrNames cfg.models)}).");
  basename = url: lib.last (lib.splitString "/" url);
  # llama-server finds the other parts of a split model next to the first.
  modelPath = "${modelsDir}/${cfg.active}/${basename (lib.head active.files).url}";

  # Flags the server must never get: each one logs prompts, keeps them, or
  # opens an endpoint nginx isn't meant to reach.
  forbiddenFlags = [
    "-v" "--verbose" "--verbose-prompt" "-lv" "--log-verbosity" "--log-file"
    "--slot-save-path" "--props" "--slots" "--metrics" "--ui" "--webui"
    "--context-shift" "-kvu" "--kv-unified" "--api-key" "--api-key-file"
    "--host" "--port" "--fit" "-fit" "-np" "--parallel" "-c" "--ctx-size"
    "-m" "--model" "-a" "--alias"
  ];
  flagsOf = model: cfg.extraFlags ++ model.extraFlags;
  # Every model's, not just the active one's, so a model is refused before
  # anyone switches to it.
  badFlags = lib.filter (f: lib.elem (lib.head (lib.splitString "=" f)) forbiddenFlags)
    (lib.concatMap flagsOf (lib.attrValues cfg.models));

  hfUrl = "^https://huggingface\\.co/[^/]+/[^/]+/resolve/[0-9a-f]{40}/.+\\.gguf$";
  allFiles = lib.concatLists (lib.mapAttrsToList (_: m: m.files) cfg.models);
  badFiles = lib.filter (f: builtins.match hfUrl f.url == null || builtins.match "[0-9a-f]{64}" f.sha256 == null) allFiles;

  serverFlags = [
    "--model" modelPath
    "--alias" "local"
    "--host" "127.0.0.1"
    "--port" (toString cfg.port)
    "--parallel" (toString cfg.parallel)
    "--ctx-size" (toString (cfg.parallel * cfg.contextPerSlot))
    "--no-kv-unified"
    "--no-context-shift"
    "--cache-type-k" cfg.kvCacheType
    "--cache-type-v" cfg.kvCacheType
    "--flash-attn" "on"
    "--n-gpu-layers" "999"
    "--fit" "off"
    "--jinja"
    "--no-ui"
    "--no-slots"
  ] ++ flagsOf active;

  server = pkgs.writeShellScript "llama-server" ''
    exec ${lib.getExe' cfg.package "llama-server"} ${lib.escapeShellArgs serverFlags}
  '';

  # One line per file: model, file name, url, sha256.
  manifest = pkgs.writeText "inference-models" (lib.concatMapStrings
    (f: "${cfg.active}\t${basename f.url}\t${f.url}\t${f.sha256}\n") active.files);

  fetchModels = pkgs.writeShellApplication {
    name = "inference-models";
    runtimeInputs = [ pkgs.curl pkgs.coreutils ];
    text = ''
      # A file counts once its hash checked out; the stamp next to it holds
      # that hash, so a new pin for the same name downloads again.
      while IFS=$'\t' read -r model file url sha256; do
        dir=${modelsDir}/$model
        mkdir -p "$dir"
        if [[ -f $dir/$file && $(cat "$dir/.$file.sha256" 2>/dev/null) == "$sha256" ]]; then
          continue
        fi
        echo "downloading $model/$file"
        curl -fsSL --retry 5 --retry-delay 15 -C - -o "$dir/$file.part" "$url"
        if ! echo "$sha256  $dir/$file.part" | sha256sum -c --status; then
          rm -f "$dir/$file.part"
          echo "$model/$file doesn't match its sha256; removed it" >&2
          exit 1
        fi
        mv -f "$dir/$file.part" "$dir/$file"
        echo "$sha256" > "$dir/.$file.sha256"
        echo "$model/$file verified"
      done < ${manifest}
    '';
  };

  hardening = {
    AmbientCapabilities = [ "" ];
    CapabilityBoundingSet = [ "" ];
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateMounts = true;
    PrivateTmp = true;
    ProcSubset = "pid";
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "strict";
    RemoveIPC = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallErrorNumber = "EPERM";
    SystemCallFilter = [ "@system-service" "~@privileged" ];
    UMask = "0077";
  };
in
{
  options.roles.inference = {
    enable = lib.mkEnableOption "llama-server with one model, on loopback";

    package = lib.mkOption {
      type = lib.types.package;
      # CUDA built for the 3090 (sm_86) only, which keeps the build short.
      default = pkgs.pkgsForCudaArch.sm_86.llama-cpp;
      defaultText = lib.literalExpression "pkgs.pkgsForCudaArch.sm_86.llama-cpp";
      description = "The llama.cpp build to serve with.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback port llama-server listens on; nginx proxies to it.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/inference";
      description = "Where the model files are kept.";
    };

    models = lib.mkOption {
      description = "Models that can be served, by name. Only `active` is downloaded and loaded.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          files = lib.mkOption {
            type = lib.types.nonEmptyListOf (lib.types.submodule {
              options = {
                url = lib.mkOption {
                  type = lib.types.str;
                  description = "Hugging Face URL pinned to a commit: https://huggingface.co/<org>/<repo>/resolve/<commit>/<file>.gguf";
                };
                sha256 = lib.mkOption {
                  type = lib.types.str;
                  description = "The file's sha256, in hex (Hugging Face shows it as the LFS oid).";
                };
              };
            });
            description = "The GGUF file, or every part of a split one with the first part first.";
          };
          extraFlags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Flags for this model only, such as sampling defaults or the reasoning default.";
          };
        };
      });
    };

    active = lib.mkOption {
      type = lib.types.str;
      description = "The model served as `local`.";
    };

    parallel = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4;
      description = "Requests served at once, each in its own slot.";
    };

    contextPerSlot = lib.mkOption {
      type = lib.types.ints.positive;
      default = 65536;
      description = "Tokens of context each request can use: room for Home Assistant's prompt, with every exposed entity, and the conversation so far.";
    };

    kvCacheType = lib.mkOption {
      type = lib.types.enum [ "f16" "q8_0" ];
      default = "q8_0";
      description = "KV cache type. q4_0 isn't offered: llama.cpp warns it degrades tool calling.";
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Flags for every model.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.models ? ${cfg.active};
        message = "roles.inference: active model ${cfg.active} isn't in models (${toString (lib.attrNames cfg.models)}).";
      }
      {
        assertion = badFiles == [ ];
        message = "roles.inference: model files must be pinned to a Hugging Face commit and carry a sha256 (not so: ${toString (map (f: f.url) badFiles)}).";
      }
      {
        assertion = badFlags == [ ];
        message = "roles.inference: these flags would log or keep prompts, open endpoints, or override what the role sets: ${toString badFlags}.";
      }
    ];

    # Nothing is written to disk when something crashes; a core dump holds
    # the prompts in memory.
    systemd.coredump.settings.Coredump.Storage = "none";

    users.users.inference = {
      isSystemUser = true;
      group = "inference";
      home = cfg.stateDir;
    };
    users.groups.inference = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 inference inference - -"
      "d ${modelsDir} 0750 inference inference - -"
    ];

    systemd.services.inference-models = {
      description = "Download and check the active model's files";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      serviceConfig = hardening // {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe fetchModels;
        User = "inference";
        Group = "inference";
        ReadWritePaths = [ modelsDir ];
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        # A big file over a slow line.
        TimeoutStartSec = "2h";
      };
    };

    systemd.services.llama-server = {
      description = "llama-server, the local model";
      wantedBy = [ "multi-user.target" ];
      requires = [ "inference-models.service" ];
      # Whisper takes its share of the card first, so the model's slots are
      # sized against what's actually left.
      after = [ "inference-models.service" "nvidia-persistenced.service" ]
        ++ lib.optional (config.virtualisation.oci-containers.containers ? wyoming-whisper) "podman-wyoming-whisper.service";
      restartTriggers = [ manifest server ];
      serviceConfig = hardening // {
        ExecStart = server;
        User = "inference";
        Group = "inference";
        SupplementaryGroups = [ "video" "render" ];
        WorkingDirectory = cfg.stateDir;
        ReadOnlyPaths = [ modelsDir ];
        Restart = "on-failure";
        RestartSec = 10;
        LimitCORE = 0;
        # The GPU needs its device nodes.
        PrivateDevices = false;
        PrivateUsers = true;
        MemoryDenyWriteExecute = true;
        # Loopback only: nginx comes in, nothing goes out.
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        IPAddressAllow = [ "localhost" ];
        IPAddressDeny = [ "any" ];
        # Loading 12-20 GB onto the card.
        TimeoutStartSec = "10min";
      };
    };
  };
}
