{ osConfig, ... }:
let
  inherit (osConfig.systemProfile) palette;
in
{
  programs.lazygit = {
    enable = true;

    # The module would also add an `lg` shell function that changes to the
    # repo lazygit was last in; not wanted here.
    enableBashIntegration = false;
    enableFishIntegration = false;
    enableNushellIntegration = false;
    enableZshIntegration = false;

    # The theme's colors. Diffs use the terminal's own colors.
    settings.gui.theme = {
      activeBorderColor = [ palette.accent "bold" ];
      inactiveBorderColor = [ palette.fg-faint ];
      searchingActiveBorderColor = [ palette.yellow "bold" ];
      optionsTextColor = [ palette.accent ];
      selectedLineBgColor = [ palette.selection ];
      inactiveViewSelectedLineBgColor = [ palette.elevated ];
      cherryPickedCommitFgColor = [ palette.on-accent ];
      cherryPickedCommitBgColor = [ palette.cyan ];
      markedBaseCommitFgColor = [ palette.on-accent ];
      markedBaseCommitBgColor = [ palette.yellow ];
      unstagedChangesColor = [ palette.red ];
      defaultFgColor = [ palette.fg ];
    };
  };
}
