{ pkgs, config, secrets, ... }:

let 
  paths = import ./modules/paths.nix;
  personalPath = "${paths.codePath}/personal";
in {
  imports = [ 
    (import ./sudoku-solver { inherit personalPath pkgs; })
  ];
}