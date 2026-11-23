# The color palettes, by theme name: the [colors] table of each <name>.toml
# in this folder, and Gneiss's from its own flake (the gneiss input,
# github.com/gneiss-theme/gneiss). systemProfile.theme is one of these
# names, and systemProfile.palette is that theme's colors.
#
# Every palette must have the same roles as Gneiss's, so an app themed from
# them works with any theme.
{ lib, gneiss }:
let
  files = lib.mapAttrs'
    (file: _: lib.nameValuePair (lib.removeSuffix ".toml" file) ./${file})
    (lib.filterAttrs (file: type: type == "regular" && lib.hasSuffix ".toml" file)
      (builtins.readDir ./.));

  palettes = lib.mapAttrs (_: file: (builtins.fromTOML (builtins.readFile file)).colors) files
    // { gneiss = gneiss.lib.palette.colors; };
  names = builtins.attrNames palettes;

  roles = builtins.attrNames palettes.gneiss;
  mismatched = lib.filter (name: builtins.attrNames palettes.${name} != roles) names;
  notHex = lib.concatLists (lib.mapAttrsToList
    (name: colors: map (role: "${name}.${role}")
      (builtins.attrNames (lib.filterAttrs (_: color: builtins.match "#[0-9A-Fa-f]{6}" color == null) colors)))
    palettes);
in
assert lib.assertMsg (mismatched == [ ])
  "themes: ${lib.concatStringsSep ", " mismatched} must have the same color roles as Gneiss's palette";
assert lib.assertMsg (notHex == [ ])
  "themes: ${lib.concatStringsSep ", " notHex} must be hex colors";
palettes
