{ pkgs, lib, config, osConfig, ... }:
let
  profile = osConfig.systemProfile;
  # nr rebuilds this host from its own checkout, by its name in the flake,
  # so it doesn't depend on where the checkout is or what the OS calls the
  # machine.
  rebuild = if pkgs.stdenv.hostPlatform.isDarwin then "darwin-rebuild" else "nixos-rebuild";
  flake = lib.escapeShellArg "${profile.nixconfigDirectory}#${profile.hostname}";
in
{
  # Add the GitHub CLI tool
  home.packages = [
    pkgs.gh
    # Dependencies for this file
    pkgs.tmux
    pkgs.jq
    pkgs.fzf
  ];

  # sops.secrets.github-cli-token = {
   # defaultSopsFile = ../../secrets/secrets.yaml;  # Adjust path as needed
   # age.keyFile = "${config.home.homeDirectory}/.config/sops/age/keys.txt";
#
#    key = "github/cli_token";
#    mode = "0400";
 # };

  programs.zsh = {
    shellAliases = {
      ghr = "searchGithubRepos";
      nr  = "sudo ${rebuild} switch --flake ${flake}";
    };

    initContent = ''
      source ~/.config/op/plugins.sh

      searchGithubRepos() {
        gh repo list --json sshUrl,name | \
          jq -r '.[] | "\(.name) \(.sshUrl)"' | \
          fzf-tmux -p | \
          awk '{print $2}' | \
          xargs git clone
      }
    '';
  };


      #export GH_TOKEN="$(cat ${config.sops.secrets.github-cli-token.path})"
    #'';
}
