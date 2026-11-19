{ inputs, pkgs, ... }:

let
  codexCli =
    inputs.codex-cli-nix.packages.${pkgs.stdenv.hostPlatform.system}.default;
in {
  imports = [
    inputs.codex-desktop-linux.homeManagerModules.default
  ];

  home.packages = [
    codexCli
  ];

  programs.codexDesktopLinux = {
    enable = true;
    
    computerUseUi.enable = true;
    remoteControl.enable = false;
    remoteMobileControl.enable = true;

    linuxFeatures = [
      "appshots"
      "open-target-discovery"
      "frameless-titlebar"
    ];
  };
}
