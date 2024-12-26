{ config, lib, pkgs, ... }:

let
  # Read and parse the JSON file
  secretsPath = ../../secrets/env.json;  # Use relative path from your nix file
   _ = builtins.trace "Looking for secrets at: ${toString secretsPath}" null;
  secrets = if builtins.pathExists secretsPath
    then 
      let contents = builtins.fromJSON (builtins.readFile secretsPath);
      in builtins.trace "Secrets loaded: ${builtins.toJSON contents}" contents
    else {};
in
{
  environment.variables = {
    DOPPLER_TOKEN = secrets.DOPPLER_TOKEN or "";
    SPECTORA_NPM_TOKEN = secrets.SPECTORA_NPM_TOKEN or "";
    FONT_AWESOME_TOKEN = secrets.FONT_AWESOME_TOKEN or "";
    BRYNTUM_AUTH_TOKEN = secrets.BRYNTUM_AUTH_TOKEN or "";
    BIT_TOKEN = secrets.BIT_TOKEN or "";
  };
}