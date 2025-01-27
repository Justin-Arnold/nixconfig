{ pkgs, ... }:

{
  # Add the GitHub CLI tool
  home.packages = [
    pkgs.gh
    # Dependencies for this file
    pkgs.tmux
    pkgs.jq
    pkgs.fzf
  ];

  programs.zsh = {
    shellAliases = {
      ghr = "searchGithubRepos";
    };

    initExtra = ''
      searchGithubRepos() {
        gh repo list --json sshUrl,name | \
          jq -r '.[] | "\(.name) \(.sshUrl)"' | \
          fzf-tmux -p | \
          awk '{print $2}' | \
          xargs git clone
      }
    ''
  }
}
