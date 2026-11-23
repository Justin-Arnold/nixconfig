{ lib, osConfig, pkgs, ... }:
let
  inherit (osConfig.systemProfile) theme;
in
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    programs.alacritty = {
      enable = true;

      # Nord comes from the alacritty-theme collection, which has no Zenwritten.
      theme = lib.mkIf (theme == "nord") "nord";

      settings = {
        # Zenbones ships its own Alacritty export alongside the Neovim theme.
        general.import = lib.mkIf (theme == "zenwritten-dark") [
          "${pkgs.vimPlugins.zenbones-nvim}/extras/alacritty/zenwritten_dark.toml"
        ];

        font = {
          normal = {
            family = osConfig.systemProfile.fonts.primary.family;
            style = "Regular";
          };
          size = 14;
        };

        window = {
          padding = {
            x = 16;
            y = 16;
          };
        };

        env = {
          TERM = "xterm-256color";
        };
      };
    };
  };
  
}
