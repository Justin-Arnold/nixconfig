# The lab MCP server (server.py next to this file): read-only tools for
# Proxmox, Beszel, Kuma and Alerta. Hermes starts it over stdio for every
# agent with observe.enable. It's the standard library plus the MCP SDK from
# nixpkgs, and starts nothing else.
{ python3, writeShellApplication }:
let
  python = python3.withPackages (ps: [ ps.mcp ]);
in
writeShellApplication {
  name = "lab-mcp-server";
  # check.nix tests server.py with this same Python.
  passthru = { inherit python; };
  text = ''
    exec ${python}/bin/python3 -I ${./server.py} "$@"
  '';
}
