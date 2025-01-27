{ pkgs, config, paths, ... }:

let 
  personalPath = "${paths.codePath}/personal";
in {
  imports = [ 
    (import ./sudoku-solver.nix { inherit personalPath pkgs; })
  ];
}