{ pkgs, lib, osConfig, ... }:

{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    programs.vscode = {
      enable = true;
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
      ];

      userSettings = {
        # Styling
        "window.autoDetectColorScheme" = true;
        "workbench.preferredDarkColorTheme" = "Nord";
        "workbench.preferredLightColorTheme" = "Nord";
        "cSpell.userWords" = [
          "pkgs"
          "Nord"
        ];
        "[json].editor.defaultFormatter" = "esbenp.prettier-vscode";
        "workbench.iconTheme" = "vscode-icons";
        "editor.fontFamily" = "Fira Code";
        "editor.fontLigatures" = true;
      };
    };
  };
}