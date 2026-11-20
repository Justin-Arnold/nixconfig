# modules/roles/text-expansion/default.nix
#
# Text expansion for NixOS GUI hosts (espanso on Wayland).
#
# Expansions are declared as groups of `name = replacement` pairs under
# roles.textExpansion.groups. The module adds ";" to each name to form its
# trigger. Every .nix file in ./snippets is imported
# automatically, so an area of expansions is added by dropping a file there
# and removed by deleting it.
#
# Expansion happens on the machine being typed on, so SSH sessions from a GUI
# host are covered without anything running on the servers.
{ config, lib, pkgs, ... }:
let
  cfg = config.roles.textExpansion;

  snippetFiles = builtins.filter (name: lib.hasSuffix ".nix" name)
    (builtins.attrNames (builtins.readDir ./snippets));

  # espanso reads YAML; JSON is valid YAML.
  matchFile = snippets: builtins.toJSON {
    matches = lib.mapAttrsToList (name: replace: {
      trigger = ";${name}";
      inherit replace;
    }) snippets;
  };

  configDir = "/etc/espanso";
in
{
  imports = map (f: ./snippets + "/${f}") snippetFiles;

  options.roles.textExpansion = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.systemProfile.hasGui;
      defaultText = lib.literalExpression "config.systemProfile.hasGui";
      description = "Whether to run the text expander on this host.";
    };

    groups = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      default = { };
      example = { base = { em = "me@example.com"; }; };
      description = "Named groups of expansions mapping unprefixed snippet names to replacement text. Each trigger starts with a semicolon.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.espanso = {
      enable = true;
      package = pkgs.espanso-wayland;
    };

    environment.etc = {
      "espanso/config/default.yml".text = builtins.toJSON { };
      # espanso creates this directory on start and panics if it cannot, so
      # it has to exist already in the read-only /etc tree.
      "espanso/match/packages/.keep".text = "";
    } // lib.mapAttrs' (group: snippets:
      lib.nameValuePair "espanso/match/${group}.yml" { text = matchFile snippets; }
    ) cfg.groups;

    # Point both the daemon and the CLI at the generated configuration.
    systemd.user.services.espanso.environment.ESPANSO_CONFIG_DIR = configDir;
    environment.sessionVariables.ESPANSO_CONFIG_DIR = configDir;
  };
}
