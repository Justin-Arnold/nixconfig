{ pkgs, lib, osConfig, ... }:
let
  gneiss = import ../../modules/common/themes/gneiss { inherit lib pkgs; };

  # The label each theme's extension gives it in VS Code.
  colorTheme = {
    zenwritten-dark = "Zenbones Zenwritten Dark";
    nord = "Nord";
    gneiss = "Gneiss";
  }.${osConfig.systemProfile.theme};
in
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    programs.vscode = {
      enable = true;
      mutableExtensionsDir = false;
      profiles.default = {
        extensions = with pkgs.vscode-extensions; [
          vue.volar
          vscode-icons-team.vscode-icons
          eamodio.gitlens
          tamasfe.even-better-toml
          streetsidesoftware.code-spell-checker
          dbaeumer.vscode-eslint
          github.copilot-chat
          oderwat.indent-rainbow
          esbenp.prettier-vscode
          bradlc.vscode-tailwindcss
          arcticicestudio.nord-visual-studio-code
          jnoortheen.nix-ide
          github.copilot
          # Built here, from modules/common/themes/gneiss.
          gneiss.vscode
        ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [
          # Zenbones themes, including Zenwritten. Not in nixpkgs.
          {
            publisher = "rpbritton";
            name = "zenbones";
            version = "0.0.3";
            hash = "sha256-YwOlDLcooUu79n4rcv832Pa+bBGrYMOKl5cUdEnrOwo=";
          }
        ];
        userSettings = {
          # Styling
          "window.autoDetectColorScheme" = true;
          "workbench.preferredDarkColorTheme" = colorTheme;
          "workbench.preferredLightColorTheme" = colorTheme;
          "cSpell.userWords" = [
            "pkgs"
            "Nord"
            "Zenbones"
            "Zenwritten"
            "Gneiss"
          ];
          "[json].editor.defaultFormatter" = "esbenp.prettier-vscode";
          "workbench.iconTheme" = "vscode-icons";
          "editor.fontFamily" = osConfig.systemProfile.fonts.primary.family;
          "editor.fontLigatures" = true;
        };
      };
    };
  };
}
