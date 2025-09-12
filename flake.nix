{
  description = "Personal Nix Configuration";

  inputs = {
    nixpkgs.url        = "github:NixOS/nixpkgs/nixos-25.05";
    # nixpkgs.url          = "github:NixOS/nixpkgs/nixos-unstable";
    zen-browser.url      = "github:MarceColl/zen-browser-flake";
    nix-homebrew.url     = "github:zhaofengli-wip/nix-homebrew";
    sops-nix.url         = "github:Mic92/sops-nix";
    nocodb.url           = "github:nocodb/nocodb";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    darwin = {
      url = "github:lnl7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    secrets = {
      url = "git+ssh://git@github.com/Justin-Arnold/private-config.git";
      flake = true;
    };
  };

  outputs = { 
    self,
    nixpkgs,
    nix-darwin,
    home-manager,
    zen-browser,
    nix-homebrew,
    secrets,
    sops-nix,
    nocodb,
    ...
  } :
  let
    lib = nixpkgs.lib;

    mkNixos = hostFile:
      lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit home-manager sops-nix; };
        modules = [
          hostFile,
          nocodb 
        ];
      };

    mkDarwin = hostFile:
      nix-darwin.lib.darwinSystem {
        system = "aarch64-darwin";
        specialArgs = { inherit home-manager; };
        modules = [ hostFile ];
      };

  in {
      nixosConfigurations = {
        terraform-controller = mkNixos ./hosts/terraform-controller/configuration.nix;
        ansible-controller = mkNixos ./hosts/ansible-controller/configuration.nix;
        slim7i = mkNixos ./hosts/slim7i/configuration.nix;
        desktop = mkNixos ./hosts/desktop/configuration.nix;
        ollama = mkNixos ./hosts/ollama/configuration.nix;
        checkmk = mkNixos ./hosts/checkmk/configuration.nix;
        gitea = mkNixos ./hosts/gitea/configuration.nix;
        nocodb = mkNixos ./hosts/nocodb/configuration.nix;
      };
      darwinConfigurations = {
        macbook16 = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          modules = [
            nix-homebrew.darwinModules.nix-homebrew
            ./hosts/macbook16/configuration.nix
            home-manager.darwinModules.home-manager
            {  # This is a separate module
              _module.args = {
                secrets = secrets.lib;
              };
            }
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              users.users.justin.home = "/Users/justin";
              home-manager.users.justin = {... }: {
                imports = [ 
                  ./home-manager/darwin-home.nix
                ];
                _module.args.secrets = secrets.lib."aarch64-darwin";
              };
            }
          ];
        };
        macmini = nix-darwin.lib.darwinSystem {
          system = "aarch64-darwin";
          modules = [
            nix-homebrew.darwinModules.nix-homebrew
            ./hosts/macmini/configuration.nix
            home-manager.darwinModules.home-manager
            {  # This is a separate module
              _module.args = {
                secrets = secrets.lib;
              };
            }
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.backupFileExtension = "backup";
              users.users.justin.home = "/Users/justin";
              home-manager.users.justin = {... }: {
                imports = [ 
                  ./home-manager/darwin-home.nix
                ];
                _module.args.secrets = secrets.lib."aarch64-darwin";
              };
            }
          ];
        };
      };
    };
}
