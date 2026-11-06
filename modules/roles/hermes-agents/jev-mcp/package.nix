# The Jev MCP server (server.py next to this file): one tool, `decide`, that
# asks TypeSafe's Jev typed questions about a piece of text. Hermes starts it
# over stdio for every agent with roles.hermesAgents.jev on. It's the
# standard library plus the MCP SDK from nixpkgs, and starts nothing else.
{ python3, writeShellApplication }:
let
  python = python3.withPackages (ps: [ ps.mcp ]);
in
writeShellApplication {
  name = "jev-mcp-server";
  # check.nix tests server.py with this same Python.
  passthru = { inherit python; };
  text = ''
    exec ${python}/bin/python3 -I ${./server.py} "$@"
  '';
}
