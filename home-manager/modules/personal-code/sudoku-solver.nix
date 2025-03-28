{ personalPath, pkgs, ... }:

{   
  # This defines the root path of the repository and pulls it down.
  home.activation.cloneSudokuSolver = {
      after = ["writeBoundary"];
      before = [];
      data = ''
      PATH="${pkgs.git}/bin:${pkgs.openssh}/bin:$PATH"
      if [ ! -d "${personalPath}/sudoku-solver" ]; then
        git clone git@github.com:Justin-Arnold/svelte-sudoku-solver.git "${personalPath}/sudoku-solver"
      fi
      '';
  };
}