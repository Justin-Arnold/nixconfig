# How flake.nix builds things: nixpkgs once per system, and the NixOS and
# nix-darwin hosts, each from hosts/<name>/configuration.nix.
{ inputs, systems }:
let
  inherit (inputs.nixpkgs) lib;

  # Module arguments every host gets. Most are also in `inputs`; hosts and
  # modules take them by name.
  specialArgs = {
    inherit inputs;
    inherit (inputs) home-manager sops-nix zen-browser disko;
  };
in
{
  # Unfree is allowed: the provisioning apps need terraform.
  pkgsFor = lib.genAttrs systems (system: import inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  });

  mkNixos = name: system: lib.nixosSystem {
    inherit system specialArgs;
    modules = [ ../hosts/${name}/configuration.nix ];
  };

  mkDarwin = name: system: inputs.darwin.lib.darwinSystem {
    inherit system;
    specialArgs = specialArgs // { inherit (inputs) p99; };
    modules = [
      inputs.nix-homebrew.darwinModules.nix-homebrew
      inputs.home-manager.darwinModules.home-manager
      ../hosts/${name}/configuration.nix
    ];
  };
}
