{ pkgs, ... }:

{

  nix-homebrew = {
    # Install Homebrew under the default prefix
    enable = true;

    # Apple Silicon Only: Also install Homebrew under the default Intel prefix for Rosetta 2
    enableRosetta = true;

    # User owning the Homebrew prefix
    user = "justin";

    # Optional: Declarative tap management
    # taps = {
    #   "homebrew/homebrew-core" = homebrew-core;
    #   "homebrew/homebrew-cask" = homebrew-cask;
    #   "homebrew/homebrew-bundle" = homebrew-bundle;
    # };

    # Optional: Enable fully-declarative tap management
    #
    # With mutableTaps disabled, taps can no longer be added imperatively with `brew tap`.
    # This must be true when also using nixos default homebrew config below
    mutableTaps = true;
  };

  homebrew = {
    enable = true;
    # onActivation.cleanup = "uninstall";

    taps = [];
    brews = [ "cowsay" ];
    casks = [
      "slite"
      "zen-browser"
      "1password"
      "discord"
      "betterdisplay"
      "raycast"
      "nikitabobko/tap/aerospace"
      "via"
      "docker" # TODO - install with nix packages
      "arc"
      "mysqlworkbench"
      "forklift"
      "bambu-studio"
      "via"
      "bartender"
      "bettertouchtool"
      "cleanmymac"
      "cleanshot"
      "iina"
      "iterm2"
      "notion"
      "notion-calendar"
    ];

    masApps = {
      "Canary Mail App" = 1236045954;
      "Session Pomodoro Focus Timer" = 1521432881;
    };
};
}