# Paperclip's MCP server (@paperclipai/mcp-server), pinned by the lockfile
# next to this file to the Paperclip release on the agents VM. Hermes starts
# it over stdio, so an agent works on Paperclip through tools instead of a
# shell, and its Paperclip key stays in that process's environment. It starts
# from run-id.mjs, which lets each call carry the Paperclip run it belongs to.
#
# To move to a new Paperclip release: change the version in package.json, run
# `npm install --package-lock-only --ignore-scripts` here, and update
# npmDepsHash (`nix run nixpkgs#prefetch-npm-deps -- package-lock.json`).
{ lib, buildNpmPackage, makeWrapper, nodejs }:

buildNpmPackage {
  pname = "paperclip-mcp-server";
  version = (lib.importJSON ./package.json).dependencies."@paperclipai/mcp-server";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [ ./package.json ./package-lock.json ./run-id.mjs ];
  };

  npmDepsHash = "sha256-N0DMGr/jVMvW+x7PfWi77HQ5p8GC2FyvoS97fiBMycw=";
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib $out/bin
    cp -r node_modules run-id.mjs $out/lib/
    makeWrapper ${lib.getExe nodejs} $out/bin/paperclip-mcp-server \
      --add-flags $out/lib/run-id.mjs
    runHook postInstall
  '';

  meta.mainProgram = "paperclip-mcp-server";
}
