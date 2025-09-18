{ pkgs, ... }:

{
  config = lib.mkIf osConfig.systemProfile.hasGui {
    home.packages = [
      pkgs.gitkraken
    ];
  };
}
