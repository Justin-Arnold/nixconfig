# modules/apps/doppler.nix
#
# Doppler CLI with one profile per account.
#
# Each profile keeps its login in its own config directory, so the tokens of
# different accounts never share a file. The `doppler` on PATH is a wrapper
# that picks the profile from the current directory and falls back to
# defaultProfile; because it is the `doppler` binary itself, shells, editors
# and scripts that call plain `doppler` all get the same answer.
#
#   doppler            profile chosen from the current directory
#   doppler-<profile>  that profile, from anywhere
#   doppler-profile    print which profile the current directory resolves to
#
# An already set DOPPLER_CONFIG_DIR is left alone, and DOPPLER_TOKEN and
# --config-dir override as they do in the stock CLI. Logging in is a one-time
# manual step per profile and machine: `doppler-<profile> login`.
{ pkgs, lib, config, ... }:
let
  cfg = config.modules.apps.doppler;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  real = "${pkgs.doppler}/bin/doppler";

  configDirOf = name: ''"$HOME"/${lib.escapeShellArg cfg.profiles.${name}.configDir}'';

  # One entry per mapped directory, longest first so the most specific wins.
  mappings = lib.sort (a: b: lib.stringLength a.dir > lib.stringLength b.dir)
    (lib.concatLists (lib.mapAttrsToList
      (name: profile: map (dir: { inherit name; dir = lib.removeSuffix "/" dir; }) profile.directories)
      cfg.profiles));

  # Sets $profile and $config_dir. macOS file systems ignore case by default,
  # so there the comparison does too.
  resolve = ''
    profile=
    config_dir=
    here="$PWD/"
    home="$HOME"
    ${lib.optionalString isDarwin ''
      here="''${here,,}"
      home="''${home,,}"
    ''}
    ${lib.concatMapStrings (m: ''
      if [ -z "$profile" ] && [[ "$here" == "$home"/${lib.escapeShellArg (if isDarwin then lib.toLower m.dir else m.dir)}/* ]]; then
        profile=${lib.escapeShellArg m.name}
        config_dir=${configDirOf m.name}
      fi
    '') mappings}
    if [ -z "$profile" ]; then
      profile=${lib.escapeShellArg cfg.defaultProfile}
      config_dir=${configDirOf cfg.defaultProfile}
    fi
  '';

  wrapper = pkgs.writeShellScript "doppler" ''
    if [ -z "''${DOPPLER_CONFIG_DIR:-}" ]; then
      ${resolve}
      export DOPPLER_CONFIG_DIR="$config_dir"
    fi
    exec ${real} "$@"
  '';

  forced = name: pkgs.writeShellScript "doppler-${name}" ''
    export DOPPLER_CONFIG_DIR=${configDirOf name}
    exec ${real} "$@"
  '';

  showProfile = pkgs.writeShellScript "doppler-profile" ''
    if [ -n "''${DOPPLER_CONFIG_DIR:-}" ]; then
      echo "DOPPLER_CONFIG_DIR is set to $DOPPLER_CONFIG_DIR, so no profile is selected"
      exit 0
    fi
    ${resolve}
    echo "$profile ($config_dir)"
  '';

  profileCommands = lib.concatStringsSep " " (map (name: "doppler-${name}") (lib.attrNames cfg.profiles));

  # Keeps the completions and man pages of the stock package.
  package = pkgs.symlinkJoin {
    name = "doppler-with-profiles";
    paths = [ pkgs.doppler ];
    postBuild = ''
      rm $out/bin/doppler
      ln -s ${wrapper} $out/bin/doppler
      ln -s ${showProfile} $out/bin/doppler-profile
      ${lib.concatMapStrings (name: ''
        ln -s ${forced name} $out/bin/doppler-${name}
      '') (lib.attrNames cfg.profiles)}

      # The stock zsh completion registers itself for `doppler` only. Register
      # it for the profile commands as well: it completes by calling the
      # command that was typed, so each one answers for its own account. The
      # grep fails the build if upstream changes the header this rewrites.
      comp=$out/share/zsh/site-functions/_doppler
      cp --remove-destination "$(readlink -f "$comp")" "$comp"
      chmod u+w "$comp"
      sed -i -E 's/^(#compdef doppler|compdef _doppler doppler)$/\1 ${profileCommands}/' "$comp"
      grep -q '^#compdef doppler ${profileCommands}$' "$comp"
      grep -q '^compdef _doppler doppler ${profileCommands}$' "$comp"
    '';
  };
in
{
  options.modules.apps.doppler = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to install the Doppler CLI.";
    };

    defaultProfile = lib.mkOption {
      type = lib.types.str;
      default = "personal";
      description = "Profile used outside every mapped directory.";
    };

    profiles = lib.mkOption {
      default = { };
      description = "Doppler accounts, each with its own config directory.";
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          configDir = lib.mkOption {
            type = lib.types.str;
            example = ".doppler-personal";
            description = "Config directory of this profile, relative to the home directory.";
          };
          directories = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "code/work" ];
            description = "Directories, relative to the home directory, in which this profile is selected.";
          };
        };
      });
    };
  };

  config = lib.mkMerge [
    {
      modules.apps.doppler.profiles.personal.configDir = lib.mkDefault ".doppler-personal";
    }
    # CGLT account, only on hosts used for CGLT work.
    (lib.mkIf config.systemProfile.forCglt {
      modules.apps.doppler.profiles.cglt = {
        configDir = ".doppler-cglt";
        directories = [ "code/cglt" ];
      };
    })
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.profiles ? ${cfg.defaultProfile};
          message = "modules.apps.doppler.defaultProfile is \"${cfg.defaultProfile}\", which is not in modules.apps.doppler.profiles.";
        }
      ];

      # hiPrio: a host may also carry the stock package (roles.dopplerSecrets).
      environment.systemPackages = [ (lib.hiPrio package) ];
    })
  ];
}
