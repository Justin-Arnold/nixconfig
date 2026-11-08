# nix build .#checks.<system>.agents-packages
#
# Builds what the agents run that no other check builds whole: the five MCP
# servers Hermes starts, the Python board-bridge and paperclip-events run
# with, and the scripts on workbench. The checks next to each test the code;
# this catches a package that no longer builds, like a Go or npm pin that
# nixpkgs moved away from, before a switch does.
{ pkgs }:
let
  mcp = name: pkgs.callPackage ../../modules/roles/hermes-agents/${name}/package.nix { };
  scripts = import ../workbench/scripts.nix { inherit pkgs; };
in
pkgs.linkFarm "agents-packages" {
  paperclip-mcp = mcp "paperclip-mcp";
  jev-mcp = mcp "jev-mcp";
  lab-mcp = mcp "lab-mcp";
  github-mcp = mcp "github-mcp";
  websearch-mcp = mcp "websearch-mcp";
  board-bridge-python = import ./board-bridge/python.nix { inherit pkgs; };
  paperclip-events-python = import ./paperclip-events/python.nix { inherit pkgs; };
  agent-worktree = scripts.agentWorktree;
  agent-review = scripts.agentReview;
  prune-worktrees = scripts.pruneWorktrees;
}
