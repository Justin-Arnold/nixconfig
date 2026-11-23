# Gneiss's ports, built from the files in this folder: each port is a
# template that names Gneiss's base colors in double braces, filled in from
# palette.toml.
{ lib, pkgs }:
let
  inherit (builtins.fromTOML (builtins.readFile ./palette.toml)) base meta;
  colorNames = builtins.attrNames base;

  render = name: template:
    let
      text = lib.replaceStrings
        (map (color: "{{${color}}}") colorNames)
        (map (color: base.${color}) colorNames)
        (builtins.readFile template);
    in
    assert lib.assertMsg (!lib.hasInfix "{{" text)
      "gneiss: ${name} names a color in double braces that isn't one of the base colors in palette.toml";
    pkgs.writeText name text;

  manifest = lib.importJSON ./vscode/package.json;
in
{
  # An Alacritty config file with the colors, to import.
  alacritty = render "gneiss-alacritty.toml" ./alacritty.toml;

  # A Neovim plugin with the "gneiss" colorscheme.
  neovim = pkgs.vimUtils.buildVimPlugin {
    pname = "gneiss";
    inherit (meta) version;
    src = pkgs.runCommandLocal "gneiss-nvim" { } ''
      install -Dm644 ${render "gneiss.lua" ./neovim.lua} "$out/colors/gneiss.lua"
      install -Dm644 ${./NOTICE} "$out/NOTICE"
    '';
  };

  # A Vicinae theme file, for Vicinae's themes folder.
  vicinae = render "gneiss.toml" ./vicinae.toml;

  # A VS Code extension with the "Gneiss" color theme.
  vscode = pkgs.vscode-utils.buildVscodeExtension {
    pname = "gneiss";
    inherit (manifest) version;
    vscodeExtPublisher = manifest.publisher;
    vscodeExtName = manifest.name;
    vscodeExtUniqueId = "${manifest.publisher}.${manifest.name}";

    dontUnpack = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/$installPrefix/themes"
      cp ${./vscode/package.json} "$out/$installPrefix/package.json"
      cp ${./NOTICE} "$out/$installPrefix/NOTICE"
      cp ${render "gneiss-color-theme.json" ./vscode/themes/gneiss-color-theme.json} \
        "$out/$installPrefix/themes/gneiss-color-theme.json"
      runHook postInstall
    '';
  };
}
