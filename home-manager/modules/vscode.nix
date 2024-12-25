{ pkgs, ... }:

{
  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      arcticicestudio.nord-visual-studio-code
      jnoortheen.nix-ide
    ];

    userSettings = {
      # Styling
      "window.autoDetectColorScheme" = true;
      "workbench.preferredDarkColorTheme" = "Nord";
      "workbench.preferredLightColorTheme" = "Nord";
    };
  };
}