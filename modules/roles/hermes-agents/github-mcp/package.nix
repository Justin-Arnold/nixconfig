# GitHub's own MCP server, read-only, for the agents with github.enable.
# nixpkgs at our pin has 1.3.0, and 1.10.0 hardened it: lockdown covers more
# tools, untrusted text is cleaned in one place, and the token only goes to
# GitHub's own hosts. So this pins 1.14.0. Later releases need Go 1.27, and
# 1.14.0 asks for Go 1.26.8 only through dependency bumps, so it builds with
# nixpkgs' Go 1.26, the same toolchain nixpkgs builds its own 1.3.0 with.
# Drop the go.mod edit once nixpkgs' Go catches up.
#
# The wrapper is what Hermes runs. It starts in an empty directory, because
# the server reads replacement tool descriptions from a JSON file in its
# working directory, and it always passes the same flags and ignores any
# arguments, so nothing in an agent's config can turn writing back on.
{ lib, go, github-mcp-server, fetchFromGitHub, writeShellApplication }:
let
  server = github-mcp-server.overrideAttrs (finalAttrs: old: {
    version = "1.14.0";
    src = fetchFromGitHub {
      owner = "github";
      repo = "github-mcp-server";
      tag = "v${finalAttrs.version}";
      hash = "sha256-94aSs+DjimLLamaR9oRLVK24KMmMzvCIUwBno6E4g1Y=";
    };
    vendorHash = "sha256-kyQH4kOV93RGuY7gCD2YVCVt4403Zwqyb/wzW/1awXM=";
    postPatch = (old.postPatch or "") + ''
      substituteInPlace go.mod --replace-fail "go 1.26.8" "go ${go.version}"
    '';
  });
in
writeShellApplication {
  name = "github-observe-mcp";
  text = ''
    cd /var/empty
    exec ${lib.getExe server} stdio --read-only --lockdown-mode --toolsets=repos,issues,pull_requests
  '';
  passthru = { inherit server; };
}
