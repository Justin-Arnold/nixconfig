{ pkgs, config, ... }:

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
      nr  = "sudo nixos-rebuild switch --flake ~/Code/personal/nixconfig";
    };

    initExtra = ''
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
