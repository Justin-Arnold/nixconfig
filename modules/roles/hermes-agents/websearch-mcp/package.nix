# The web search MCP server (server.py next to this file): search_web through
# the lab's own SearXNG, and read_page for pages that search found. Hermes
# starts it over stdio for every agent with web.enable on. It's the standard
# library, the MCP SDK and trafilatura (for a page's main text) from nixpkgs.
{ python3, writeShellApplication }:
let
  python = python3.withPackages (ps: [ ps.mcp ps.trafilatura ]);
in
writeShellApplication {
  name = "websearch-mcp-server";
  # check.nix tests server.py with this same Python.
  passthru = { inherit python; };
  text = ''
    exec ${python}/bin/python3 -I ${./server.py} "$@"
  '';
}
