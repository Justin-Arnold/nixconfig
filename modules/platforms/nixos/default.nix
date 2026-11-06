{ home-manager, pkgs, inputs, lib, sops-nix, zen-browser, config, ... }: {
  imports = [ home-manager.nixosModules.home-manager ./desktopEnvironments ./apps ];

  system.stateVersion = config.systemProfile.stateVersion;

  ############################################################
  ## DNS
  ############################################################
  # Lab hosts resolve through the lab router. Hosts outside the lab
  # (lab118-services) override this with public resolvers.
  networking.nameservers = lib.mkDefault [
    "10.0.0.1"
  ];

  services.resolved.enable = true;

  ############################################################
  ## User Configuration
  ############################################################
  users.users."${config.systemProfile.username}" = {
    isNormalUser = true;
    group = config.systemProfile.username;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" "networkmanager" ];
  };
  users.groups."${config.systemProfile.username}" = {};

  modules = {
    apps = {
      # 1Password desktop app (and its SSH agent) only where there is a GUI.
      # Every host keeps the `op` CLI from modules/common.
      onepassword = {
        enable = config.systemProfile.hasGui;
        polkit.enable = true;
      };
      zoxide = {
        enable = true;
        replaceCd = true;
      };
      bluebubbles = {
        enable = config.systemProfile.hasGui;
      };
      openbubbles = {
        enable = config.systemProfile.hasGui;
      };
      greenlight = {
        enable = config.systemProfile.hasGui;
      };
    };

    roles.nixos.desktopEnvironments = {
      hyprland = { enable = config.systemProfile.hasGui; };
    };
  };

  programs.zsh.enable = true;
  #programs.ssh.startAgent = true;
  #programs.ssh.extraConfig = ''
  # Host *
  #     AddKeysToAgent yes
  #     IdentitiesOnly yes
  #'';

  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";
  home-manager.extraSpecialArgs = { inherit inputs zen-browser; };
  home-manager.sharedModules = [
    sops-nix.homeManagerModules.sops
    inputs._1password-shell-plugins.hmModules.default
    (import "${pkgs.hyprshell.src}/nix/module.nix" {
      packages.${pkgs.stdenv.hostPlatform.system}.hyprshell = pkgs.hyprshell;
    })
  ];
  home-manager.users.${config.systemProfile.username} = { ... }: {
    # home/roles/nixos.nix is the desktop role (Codex desktop, krusader,
    # Alacritty popups, hyprshell, GTK/Qt theming, 1Password SSH agent), so
    # only GUI hosts get it. Servers keep the terminal environment in base.nix.
    imports = [ ../../../home/roles/base.nix ]
      ++ lib.optional config.systemProfile.hasGui ../../../home/roles/nixos.nix;
  };
}
