# Every flake check, by name. CI builds each attribute of checks.x86_64-linux
# as its own job (.github/workflows/check.yml), so these names are what it
# shows; scripts/flake-check.sh builds them locally.
#
# Each check lives next to what it tests; this file only gives them names.
{ self, lib, systems, pkgsFor, infraManifest }:
let
  # The hosts with an eval-test.nix: the real host with example values and no
  # SOPS file, so it evaluates, every assertion included, on any machine.
  # Built once and shared by both systems' checks.
  examples = lib.genAttrs [
    "agents"
    "automation"
    "cglt-previews"
    "dashboard"
    "inference"
    "lab118-services"
    "openclaw"
    "workbench"
  ] (host: self.nixosConfigurations.${host}.extendModules {
    modules = [ ../hosts/${host}/eval-test.nix ];
  });

  drvPathOf = nixos: nixos.config.system.build.toplevel.drvPath;

  # Each host's hosts/<host>/exposure-guards.nix: modules that each break the
  # host's exposure policy. Evaluating the example with any of them has to
  # fail. The example itself has to evaluate first, or every case would fail
  # for that reason and look refused.
  guardResults = lib.mapAttrs (host: example:
    let
      cases = import ../hosts/${host}/exposure-guards.nix { inherit lib example; };
      refused = module: !(builtins.tryEval
        (example.extendModules { modules = [ module ]; }).config.system.build.toplevel.drvPath).success;
      exampleEvaluates = builtins.addErrorContext
        "while checking that hosts/${host}/eval-test.nix evaluates, before trying its exposure cases"
        (drvPathOf example);
      results = builtins.seq exampleEvaluates (lib.mapAttrs (_: refused) cases);
    in
    assert lib.assertMsg (lib.all lib.id (lib.attrValues results))
      "${host} exposure guards did not refuse: ${toString (lib.attrNames (lib.filterAttrs (_: ok: !ok) results))}";
    results) examples;
in
lib.genAttrs systems (system:
  let
    pkgs = pkgsFor.${system};
  in
  {
    doppler-secrets = import ../modules/roles/doppler-secrets/check.nix { inherit pkgs lib; };
    sqlite-backup = import ../modules/roles/sqlite-backup/check.nix { inherit pkgs lib; };
    scene = import ../modules/roles/scene/check.nix { inherit pkgs; };
    agent-watch = import ../hosts/agents/agent-watch/check.nix { inherit pkgs; };
    agent-costs = import ../hosts/agents/agent-costs/check.nix { inherit pkgs; };
    lab-health = import ../hosts/agents/lab-health/check.nix { inherit pkgs; };
    board-bridge = import ../hosts/agents/board-bridge/check.nix { inherit pkgs; };
    paperclip-events = import ../hosts/agents/paperclip-events/check.nix { inherit pkgs; };
    jev-mcp = import ../modules/roles/hermes-agents/jev-mcp/check.nix { inherit pkgs; };
    paperclip-mcp = import ../modules/roles/hermes-agents/paperclip-mcp/check.nix { inherit pkgs; };
    websearch-mcp = import ../modules/roles/hermes-agents/websearch-mcp/check.nix { inherit pkgs; };
    lab-mcp = import ../modules/roles/hermes-agents/lab-mcp/check.nix { inherit pkgs; };
    notifications-stack = import ../modules/roles/notifications-stack/check.nix { inherit pkgs; };
    provisioning = import ../scripts/provisioning/tests/check.nix {
      inherit pkgs;
      manifest = infraManifest.${system};
    };
    cglt-previews-preview-ctl = import ../hosts/cglt-previews/preview-ctl-check.nix { inherit pkgs; };
    paperclip-spec = import ../hosts/agents/paperclip-spec-check.nix {
      inherit pkgs lib;
      agents = self.nixosConfigurations.agents.config;
    };
    inference-eval = import ../hosts/inference/models-check.nix {
      inherit pkgs lib;
      example = examples.inference;
      models = self.nixosConfigurations.inference.config.roles.inference.models;
    };
  }
  # <host>-eval: the example evaluates. (inference-eval, above, does this per model.)
  // lib.listToAttrs (map
    (host: lib.nameValuePair "${host}-eval" (pkgs.writeText "${host}-eval"
      (builtins.unsafeDiscardStringContext (drvPathOf examples.${host}))))
    [ "agents" "automation" "cglt-previews" "dashboard" "lab118-services" "openclaw" "workbench" ])
  # <host>-exposure-guards: see guardResults.
  // lib.mapAttrs'
    (host: results: lib.nameValuePair "${host}-exposure-guards"
      (pkgs.writeText "${host}-exposure-guards" (builtins.toJSON results)))
    guardResults
  // lib.optionalAttrs (lib.hasSuffix "-linux" system) {
    # What the agents run, which only ever runs on Linux.
    agents-packages = import ../hosts/agents/packages-check.nix { inherit pkgs; };
  })
