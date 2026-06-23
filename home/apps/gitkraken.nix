{ pkgs, lib, osConfig, ... }:

# GitKraken has an issue with honoring GUI scaling in linux
# so this file is a little more cumbersome to ensure we pass
# the required flag to the program to make sure it matches our
# desired UI scaling

let
  gitkrakenScaled = pkgs.symlinkJoin {
    name = "gitkraken-scaled";
    paths = [ pkgs.gitkraken ];

    nativeBuildInputs = [ pkgs.makeWrapper ];

    postBuild = ''
      wrapProgram $out/bin/gitkraken \
        --add-flags "--force-device-scale-factor=1.25"
    '';
  };
in {
  config = lib.mkIf osConfig.systemProfile.hasGui {
    home.packages = [
      gitkrakenScaled
    ];

    # This makes sure the app launchers using the wrapped binary
    xdg.desktopEntries.gitkraken = {
      name = "GitKraken";
      genericName = "Git Client";
      exec = "gitkraken %U";
      icon = "gitkraken";
      terminal = false;
      categories = [ "Development" ];
    };
  };
}
