{ lib, pkgs, config, ... }:
{
  # options.my.isDesktop = lib.mkEnableOption "Enable GUI/desktop HM apps.";

  home.username = lib.mkDefault "justin";
  home.homeDirectory = lib.mkDefault (
    if pkgs.stdenv.hostPlatform.isDarwin
      then "/Users/${config.home.username}"
      else "/home/${config.home.username}"
  );

  programs.home-manager.enable = lib.mkDefault true;

  programs.git = {
    enable = true;
    userName = "Justin Arnold";
    userEmail = "hello@justin-arnold.com";
  };

  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    pkgs.hello
    pkgs.zsh-powerlevel10k
  ];

  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';

    #".config/tmux/tmux.conf".source = ../tmux/tmux.conf;
    ".p10k.zsh".source = ../dotfiles/p10k.zsh;
  };

  programs.zsh = {
    enable = true;

    initExtra = ''
      eval "$(direnv hook zsh)"
      source ~/.p10k.zsh
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