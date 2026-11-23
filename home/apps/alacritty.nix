{ lib, osConfig, pkgs, ... }:
let
  inherit (osConfig.systemProfile) theme;
  gneiss = import ../../modules/common/themes/gneiss { inherit lib pkgs; };

  # The colors file to import, for the themes that aren't in the
  # alacritty-theme collection.
  colorsFile = {
    # Zenbones ships its own Alacritty export alongside the Neovim theme.
    zenwritten-dark = "${pkgs.vimPlugins.zenbones-nvim}/extras/alacritty/zenwritten_dark.toml";
    gneiss = "${gneiss.alacritty}";
  };
in
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    programs.alacritty = {
      enable = true;

      # Nord comes from the alacritty-theme collection.
      theme = lib.mkIf (theme == "nord") "nord";

      settings = {
        general.import = lib.mkIf (colorsFile ? ${theme}) [ colorsFile.${theme} ];

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
