# The color palettes in this folder, by theme name: the [colors] table of
# each <name>.toml, or of <name>/palette.toml for a theme that has its own
# folder (Gneiss, whose ports live next to its palette). systemProfile.theme
# is one of these names, and systemProfile.palette is that theme's colors.
#
# A color in [colors] is a hex, or the name of one of the file's [base]
# colors. Every palette must have the same roles, so an app themed from
# them works with any theme.
{ lib }:
let
  entries = builtins.readDir ./.;

  files = lib.mapAttrs'
    (file: _: lib.nameValuePair (lib.removeSuffix ".toml" file) ./${file})
    (lib.filterAttrs (file: type: type == "regular" && lib.hasSuffix ".toml" file) entries);

  folders = lib.mapAttrs
    (folder: _: ./${folder}/palette.toml)
    (lib.filterAttrs (folder: type: type == "directory" && builtins.pathExists ./${folder}/palette.toml) entries);

  load = file:
    let
      toml = builtins.fromTOML (builtins.readFile file);
      base = toml.base or { };
    in
    lib.mapAttrs (_: color: base.${color} or color) toml.colors;

  palettes = lib.mapAttrs (_: load) (files // folders);
  names = builtins.attrNames palettes;

  roles = builtins.attrNames palettes.zenwritten-dark;
  mismatched = lib.filter (name: builtins.attrNames palettes.${name} != roles) names;
  notHex = lib.concatLists (lib.mapAttrsToList
    (name: colors: map (role: "${name}.${role}")
      (builtins.attrNames (lib.filterAttrs (_: color: builtins.match "#[0-9A-Fa-f]{6}" color == null) colors)))
    palettes);
in
assert lib.assertMsg (mismatched == [ ])
  "themes: ${lib.concatStringsSep ", " mismatched} must have the same color roles as zenwritten-dark.toml";
assert lib.assertMsg (notHex == [ ])
  "themes: ${lib.concatStringsSep ", " notHex} must be a hex color or one of the palette's [base] colors";
palettes
