# The color palettes in this folder, by theme name: each <name>.toml's
# [colors] table. systemProfile.theme is one of these names, and
# systemProfile.palette is that theme's colors.
#
# Every palette must have the same roles, so an app themed from them works
# with any theme.
{ lib }:
let
  names = map (lib.removeSuffix ".toml")
    (lib.filter (lib.hasSuffix ".toml") (builtins.attrNames (builtins.readDir ./.)));

  palettes = lib.genAttrs names (name:
    (builtins.fromTOML (builtins.readFile ./${name}.toml)).colors);

  roles = builtins.attrNames palettes.zenwritten-dark;
  mismatched = lib.filter (name: builtins.attrNames palettes.${name} != roles) names;
in
assert lib.assertMsg (mismatched == [ ])
  "themes: ${lib.concatStringsSep ", " mismatched} must have the same color roles as zenwritten-dark.toml";
palettes
