{
  description = "Personal Nix Configuration";

  inputs = {
    # The base: packages, home-manager, and nix-darwin with Homebrew.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew.url = "github:zhaofengli-wip/nix-homebrew";

    # Secrets and disk layouts on the hosts.
    sops-nix.url = "github:Mic92/sops-nix";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Provisioning (flake/provisioning.nix): Terraform from Nix, and installs.
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-anywhere = {
      url = "github:nix-community/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Apps for the desktops and Macs.
    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    _1password-shell-plugins.url = "github:1Password/shell-plugins";
    codex-desktop-linux.url = "github:ilysenko/codex-desktop-linux";
    codex-cli-nix.url = "github:sadjow/codex-cli-nix/main";
    claude-desktop = {
      url = "github:aaddrick/claude-desktop-debian";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    p99.url = "github:Justin-Arnold/p99";

    # The agents VM's Hermes instances (roles.hermesAgents), pinned to a
    # release. Its own nixpkgs builds it; home-manager is only for its checks.
    hermes-agent = {
      url = "github:NousResearch/hermes-agent/v0.22.5";
      inputs.home-manager.follows = "home-manager";
    };
    nix-openclaw = {
      url = "github:openclaw/nix-openclaw/v2026.10.7";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
  };

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # What the checks and the provisioning apps are built for.
      systems = [ "aarch64-darwin" "x86_64-linux" ];

      inherit (import ./flake/builders.nix { inherit inputs systems; }) pkgsFor mkNixos mkDarwin;
      provisioning = import ./flake/provisioning.nix { inherit inputs lib systems pkgsFor; };
    in
    {
      # Each is hosts/<name>/configuration.nix, built for that system.
      # scripts/flake-check.sh lists the ones that no longer evaluate.
      nixosConfigurations = lib.mapAttrs mkNixos {
        agents = "x86_64-linux";
        automation = "x86_64-linux";
        cglt-previews = "x86_64-linux";
        checkmk = "x86_64-linux";
        dashboard = "x86_64-linux";
        desktop = "x86_64-linux";
        dockhand = "x86_64-linux";
        gitea = "x86_64-linux";
        github-runner = "x86_64-linux";
        inference = "x86_64-linux";
        lab118-services = "x86_64-linux";
        notifications = "x86_64-linux";
        omada-controller = "x86_64-linux";
        onepassword-connect = "x86_64-linux";
        openclaw = "x86_64-linux";
        pangolin-newt = "x86_64-linux";
        parallels = "aarch64-linux";
        pr-previews = "x86_64-linux";
        slim7i = "x86_64-linux";
        terraform-controller = "x86_64-linux";
        uptime-kuma = "x86_64-linux";
        vikunja = "x86_64-linux";
        workbench = "x86_64-linux";
      };
      darwinConfigurations = lib.mapAttrs mkDarwin {
        macbook16 = "aarch64-darwin";
        macmini = "aarch64-darwin";
      };

      # Rendered Terraform and `nix run .#<action>` (scripts/provisioning).
      inherit (provisioning) terranixConfigurations apps;

      # Every check by name; each lives next to what it tests.
      checks = import ./flake/checks.nix {
        inherit self lib systems pkgsFor;
        inherit (provisioning) infraManifest;
      };
    };
}
