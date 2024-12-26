{ config, pkgs, ... }:

{
  programs.git = {
    enable = true;
    userName  = "Justin Arnold";
    userEmail = "hello@justin-arnold.com";
  };

  services.githubSsh.enable = true;
}