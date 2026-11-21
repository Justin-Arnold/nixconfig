# nix build .#checks.<system>.paperclip-spec
#
# The Hermes agents in Paperclip's spec are the ones on the agents host, at their ports, and
# every routine has an agent from the spec and its description file. `agents` is the real
# host's config, not the eval-test example.
{ pkgs, lib, agents }:
let
  spec = lib.importJSON ../../scripts/agents/paperclip-spec.json;
  onHost = lib.mapAttrs (_: agent: "http://127.0.0.1:${toString agent.port}")
    agents.roles.hermesAgents.instances;
  inSpec = lib.listToAttrs (map (agent: lib.nameValuePair (lib.toLower agent.name) agent.adapterConfig.apiBaseUrl)
    (lib.filter (agent: agent.adapterType == "hermes_gateway") spec.agents));
  names = map (agent: agent.name) spec.agents;
  badRoutines = lib.filter (routine: !(lib.elem routine.assignee names)
    || !(builtins.pathExists (../../scripts/agents + "/${routine.descriptionFile}"))) (spec.routines or [ ]);
  watch = agents.agents.watch;
  triage = lib.findFirst (routine: routine.title == watch.intake.routineTitle) null (spec.routines or [ ]);
  health = agents.agents.labHealth;
  findings = lib.findFirst (routine: routine.title == health.routineTitle) null (spec.routines or [ ]);
in
assert lib.assertMsg (onHost == inSpec)
  "scripts/agents/paperclip-spec.json doesn't match hosts/agents/agents.nix: ${builtins.toJSON { inherit onHost inSpec; }}";
assert lib.assertMsg (badRoutines == [ ])
  "scripts/agents/paperclip-spec.json: these routines name an agent or a description file that doesn't exist: ${builtins.toJSON (map (r: r.title) badRoutines)}";
# n8n starts the triage through this routine's webhook and waits while one of its issues is open;
# agent-watch finds it by its title.
assert lib.assertMsg (!(watch.enable && watch.intake.enable) || (triage != null && triage.assignee == "Monitor"
  && lib.any (trigger: trigger.kind == "webhook" && (trigger.watchOpen or false)) (triage.triggers or [ ])))
  "scripts/agents/paperclip-spec.json has no routine for the monitor titled ${builtins.toJSON watch.intake.routineTitle} with a webhook trigger that has watchOpen (agents.watch.intake.routineTitle)";
# lab-health runs this routine by its title with the monitor's key, which runs only the monitor's own.
assert lib.assertMsg (!health.active || (findings != null && findings.assignee == "Monitor"))
  "scripts/agents/paperclip-spec.json has no routine for the monitor titled ${builtins.toJSON health.routineTitle} (agents.labHealth.routineTitle)";
pkgs.writeText "paperclip-spec" (builtins.toJSON inSpec)
