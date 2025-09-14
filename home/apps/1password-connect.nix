{ pkgs, osConfig, ... }:
{
  home.file.".envrc".text = ''
    dotenv "/run/secrets/onepassword.env"
  '';
}