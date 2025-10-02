# home.nix
{ config, pkgs, ... }:

{
  home.packages = [
    (pkgs.writeShellScriptBin "oterm" ''
      export OLLAMA_URL="http://10.0.0.63:11434"
      exec ${pkgs.oterm}/bin/oterm "$@"
    '')
  ];
  home.sessionVariables = { OLLAMA_URL = "http://10.0.0.63:11434"; };
  # Create the popup script
  home.file.".local/bin/oterm-popup" = {
    text = ''
      #!/usr/bin/env bash
      alacritty --class oterm-popup -e oterm
    '';
    executable = true;
  };
}
