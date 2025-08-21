{ osConfig,lib, ... }:
{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    programs.alacritty = {
      enable = true;
      settings = {
        font = {
          normal = {
            family = "FiraCode Nerd Font";
            style = "Regular";
          };
          size = 14;
        };

        colors = {
          primary = {
            background = "#2E3440";
            foreground = "#D8DEE9";
          };

          normal = {
            black   = "#3B4252";
            red     = "#BF616A";
            green   = "#A3BE8C";
            yellow  = "#EBCB8B";
            blue    = "#81A1C1";
            magenta = "#B48EAD";
            cyan    = "#88C0D0";
            white   = "#E5E9F0";
          };

          bright = {
            black   = "#4C566A";
            red     = "#BF616A";
            green   = "#A3BE8C";
            yellow  = "#EBCB8B";
            blue    = "#81A1C1";
            magenta = "#B48EAD";
            cyan    = "#8FBCBB";
            white   = "#ECEFF4";
          };
        };

        window = {
          padding = {
            x = 16;
            y = 0;
          };
        };

        env = {
          TERM = "xterm-256color";
        };
      };
    };
  };
  
}
