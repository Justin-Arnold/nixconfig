{ pkgs, ... }:

{
  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      vue.volar
      github.copilot-chat
      vscode-icons-team.vscode-icons
      eamodio.gitlens
      tamasfe.even-better-toml
      svelte.svelte-vscode
      streetsidesoftware.code-spell-checker
      dbaeumer.vscode-eslint
      oderwat.indent-rainbow
      esbenp.prettier-vscode
      bradlc.vscode-tailwindcss
      arcticicestudio.nord-visual-studio-code
      jnoortheen.nix-ide
      github.copilot
      github.copilot-chat
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
      "workbench.iconTheme" = "vscode-icons";
      "editor.fontFamily" = "Fira Code";
      "editor.fontLigatures" = true;
    };
  };
}