{ pkgs, ... }:

{
  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      streetsidesoftware.code-spell-checker
      dbaeumer.vscode-eslint
      oderwat.indent-rainbow
      esbenp.prettier-vscode
      bradlc.vscode-tailwindcss
      arcticicestudio.nord-visual-studio-code
      jnoortheen.nix-ide
      vue.volar
    ];

    userSettings = {
      # Styling
      "window.autoDetectColorScheme" = true;
      "workbench.preferredDarkColorTheme" = "Nord";
      "workbench.preferredLightColorTheme" = "Nord";
      "cSpell.userWords" = [
        "pkgs"
        "Nord"
        "spectora"
      ];
      "[json].editor.defaultFormatter" = "esbenp.prettier-vscode";
    };
  };
}