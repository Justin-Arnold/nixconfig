{ config, lib, pkgs, ... }: 

let
    nodePkgs = import ./node-source.nix { inherit pkgs; };
in {
    options.services.node = {
        versions = lib.mkOption {
            type = lib.types.attrsOf lib.types.package;
            default = {};
        };
    };

    config.home.packages = builtins.attrValues config.services.node.versions;
}