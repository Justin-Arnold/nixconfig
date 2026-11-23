{ pkgs, osConfig, ... }:
let
  # Each theme's Neovim plugin, and the Lua that turns it on.
  colorscheme = {
    zenwritten-dark = {
      # Zenbones uses Lush when it is installed; without it, it would need
      # g:zenbones_compat = 1.
      plugins = [ pkgs.vimPlugins.lush-nvim ];
      plugin = pkgs.vimPlugins.zenbones-nvim;
      config = ''
        vim.o.background = "dark"
        vim.cmd.colorscheme("zenwritten")
      '';
    };
    nord = {
      plugins = [ ];
      plugin = pkgs.vimPlugins.gbprod-nord;
      config = ''
        require("nord").setup({})
        vim.cmd.colorscheme("nord")
      '';
    };
  }.${osConfig.systemProfile.theme};
in
{
  programs.neovim = {
    enable = true;

    plugins = colorscheme.plugins ++ [
      {
        inherit (colorscheme) plugin;
        type = "lua";
        config = ''
          vim.o.termguicolors = true
        '' + colorscheme.config;
      }
    ];
  };

  #home.file = {
  #  ".config/nvim/init.lua".source = ../dotfiles/nvim/init.lua;
	#	".config/nvim/lua/config".source = ../dotfiles/nvim/config;
  #  ".config/nvim/lua/plugins".source = ../dotfiles/nvim/plugins;
  #};
}
