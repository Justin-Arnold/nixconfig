#{
#  description = "Nix Configuration";
#
#  inputs = {
#    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
#    home-manager = {
#      url = "github:nix-community/home-manager";
#      inputs.nixpkgs.follows = "nixpkgs";
#    };
#  };
#
#  outputs = { self, nixpkgs, home-manager, ... }:
#    let
#      # Determine the target system at runtime
#      system = "x86_64-linux";
#      pkgs = nixpkgs.legacyPackages.${system};
#    in
#    {
#      # Define NixOS configurations only for Linux systems
#      nixosConfigurations = {
#          thinkpad = nixpkgs.lib.nixosSystem {
#            inherit system;
#            modules = [
#              ./hosts/thinkpad/configuration.nix
#              home-manager.nixosModules.home-manager
#              {
#                home-manager.useGlobalPkgs = true;
#                home-manager.useUserPackages = true;
#                home-manager.users.justin = import ./home-manager/justin.nix;
#             }
#            ];
#          };
#        };      
#    };
#}
{
  description = "Test Nix Configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    zen-browser.url = "github:MarceColl/zen-browser-flake";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = { self, nixpkgs, home-manager, zen-browser, ... }:
    let
      lib = nixpkgs.lib;
    in {
      nixosConfigurations = {
        thinkpad = lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/thinkpad/configuration.nix
            # Add any additional modules here
            {
              # Integrate Home Manager
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.justin = import ./home-manager/home.nix;
            }
          ];
          specialArgs = { inherit self; inherit nixpkgs; };
        };
        slim7i = lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./hosts/slim7i/configuration.nix
            # Add any additional modules here
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              home-manager.users.justin = import ./home-manager/home.nix;
            }
          ];
          specialArgs = { inherit self; inherit zen-browser;};
        };
      };
    };
}
