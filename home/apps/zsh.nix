{ pkgs, ... }:
{
  home.packages = [
    pkgs.zsh-powerlevel10k
  ];

  home.file = {
    ".p10k.zsh".source = ../dotfiles/p10k.zsh;
  };

  programs.zsh = {
    enable = true;

    initExtra = ''
      eval "$(direnv hook zsh)"
      source ~/.p10k.zsh

      export VOLTA_HOME="$HOME/.volta"
      export PATH="$VOLTA_HOME/bin:$PATH"
    '';
    plugins =  [
      {
        name = "powerlevel10k";
        src = pkgs.zsh-powerlevel10k;
        file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      }
    ];
    oh-my-zsh = {
      enable = true;
      theme = "robbyrussell";
    };
  };
}