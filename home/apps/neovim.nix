{ pkgs, ... }:

{
  programs.neovim.enable = true;

  home.file = {
    ".config/nvim/init.lua".source = ../dotfiles/nvim/init.lua;
    ".config/nvim/lua/plugins".source = ../dotfiles/nvim/plugins;
  };
}
