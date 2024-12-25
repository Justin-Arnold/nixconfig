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
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-homebrew.url = "github:zhaofengli-wip/nix-homebrew";
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, zen-browser, nix-homebrew, ... }:
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
      darwinConfigurations = {
        macbook16 = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
   	  modules = [
	    nix-homebrew.darwinModules.nix-homebrew
	    ./hosts/macbook16/configuration.nix
	    home-manager.darwinModules.home-manager
	    {
	      home-manager.useGlobalPkgs = true;
	      home-manager.useUserPackages = true;
	      home-manager.backupFileExtension = "backup";
	      users.users.justin.home = "/Users/justin";
	      home-manager.users.justin = import ./home-manager/darwin-home.nix;
	    }
	  ];
        };
        macmini = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          modules = [
            nix-homebrew.darwinModules.nix-homebrew
            ./hosts/macmini/configuration.nix
            home-manager.darwinModules.home-manager
	    {
	      home-manager.useGlobalPkgs = true;
	      home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
	      users.users.justin.home = "/Users/justin";
              home-manager.users.justin = import ./home-manager/darwin-home.nix;
	    }
  	  ];
	};
      };
    };
}
