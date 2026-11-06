# The scripts the agents use on workbench, packaged. agents.nix installs
# them, and the agents-packages check builds them, which shellchecks each.
{ pkgs }:
{
  agentWorktree = pkgs.writeShellApplication {
    name = "agent-worktree";
    runtimeInputs = [ pkgs.git pkgs.coreutils ];
    text = builtins.readFile ./agent-worktree.sh;
  };

  agentReview = pkgs.writeShellApplication {
    name = "agent-review";
    runtimeInputs = [ pkgs.git pkgs.coreutils ];
    text = builtins.readFile ./agent-review.sh;
  };

  pruneWorktrees = pkgs.writeShellApplication {
    name = "prune-worktrees";
    runtimeInputs = [ pkgs.git pkgs.coreutils pkgs.findutils pkgs.gnused pkgs.gnugrep ];
    text = builtins.readFile ./prune-worktrees.sh;
  };
}
