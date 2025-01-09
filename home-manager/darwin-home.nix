{ pkgs, lib, config, secrets, ... }:

let 
  paths = import ./modules/paths.nix;
in {
  imports =
    [ 
      #./nvim.nix
      ./modules/alacritty.nix
      ./modules/vscode.nix
      ./modules/obsidian.nix
      ./modules/defaultbrowser.nix
      ./modules/slack.nix
      ./modules/gitkraken.nix
      ./modules/yarn.nix
      ./modules/doppler.nix
      ./modules/aerospace.nix
      ./modules/direnv.nix
      ./modules/node.nix
      (import ./modules/cglt { inherit paths pkgs secrets config; }) 
    ];

  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "justin";
  home.homeDirectory = "/Users/justin";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "24.05"; # Please read the comment before changing.

  fonts.fontconfig.enable = true;

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    pkgs.hello

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
    #pkgs.tmux
    pkgs.zsh-powerlevel10k
    (pkgs.nerdfonts.override { fonts = [ "FiraCode" "DroidSansMono" ]; })
    #pkgs.lazygit
    #zenBrowserPackage
  ];

  

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
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
    ".p10k.zsh".source = ./dotfiles/p10k.zsh;
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/justin/etc/profile.d/hm-session-vars.sh
  #
  #home.sessionVariables = {
  #  # EDITOR = "emacs";
  #};

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  programs.git = {
    enable = true;
    userName = "Justin Arnold";
    userEmail = "hello@justin-arnold.com";
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
