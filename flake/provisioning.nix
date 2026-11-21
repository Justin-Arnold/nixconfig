# What scripts/provisioning/provision-host.sh needs from the flake: each
# infra-managed host's rendered Terraform (infra/terranix), a manifest of
# those hosts, and the `nix run .#<action>` apps that run the script with it.
{ inputs, lib, systems, pkgsFor }:
let
  terranixHosts = import ../infra/terranix { inherit inputs; };

  actions = [ "plan" "provision" "install" "switch" "destroy" "adopt" "migrate-state" ];
in
rec {
  terranixConfigurations = lib.genAttrs systems (system:
    lib.mapAttrs (_: host: inputs.terranix.lib.terranixConfiguration {
      inherit system;
      modules = [ host.module ];
    }) terranixHosts);

  # Per-host platform, rendered Terraform JSON, deploy target and whether the
  # host installs with its own age key, read by provision-host.sh. The
  # provisioning check tests the script against the same file.
  infraManifest = lib.genAttrs systems (system:
    pkgsFor.${system}.writeText "nixconfig-infra-hosts.json" (builtins.toJSON (lib.mapAttrs
      (name: host: {
        inherit (host) platform;
        terraformConfig = "${terranixConfigurations.${system}.${name}}";
        deployTarget = host.deployTarget or null;
        hostAgeKey = host.hostAgeKey or false;
      })
      terranixHosts)));

  apps = lib.genAttrs systems (system:
    let
      pkgs = pkgsFor.${system};
      app = action:
        let
          provisionApp = pkgs.writeShellApplication {
            name = "nixconfig-${action}";
            runtimeInputs = [
              pkgs.age
              pkgs.curl
              pkgs.git
              pkgs.jq
              pkgs.nixos-rebuild
              pkgs.openssh
              pkgs.sops
              pkgs.terraform
              inputs.nixos-anywhere.packages.${system}.default
            ];
            text = ''
              export NIX_INFRA_ACTION=${action}
              export NIXCONFIG_INFRA_HOSTS=${infraManifest.${system}}
              export NIXCONFIG_PLAN_GUARD=${../scripts/provisioning/plan-guard.jq}
              export NIXCONFIG_PROXMOX_PLAN_GUARD=${../scripts/provisioning/proxmox-plan-guard.jq}
              exec bash ${../scripts/provisioning/provision-host.sh} "$@"
            '';
          };
        in
        {
          type = "app";
          program = "${provisionApp}/bin/nixconfig-${action}";
        };
    in
    lib.genAttrs actions app);
}
