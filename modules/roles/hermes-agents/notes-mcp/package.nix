# The notes MCP server (server.py next to this file): Justin's vault through
# the vault service's socket on the agents host. Hermes starts it over stdio
# for every agent with notes.enable on. It's the standard library plus the
# MCP SDK from nixpkgs, and holds no key.
{ python3, writeShellApplication }:
let
  python = python3.withPackages (ps: [ ps.mcp ]);
in
writeShellApplication {
  name = "notes-mcp-server";
  # check.nix tests server.py with this same Python.
  passthru = { inherit python; };
  text = ''
    exec ${python}/bin/python3 -I ${./server.py} "$@"
  '';
}
