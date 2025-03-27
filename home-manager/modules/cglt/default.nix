{ paths, pkgs, secrets, config }:
let
    cgltPath = "${paths.codePath}/cglt";
    # TODO - Create service in nix repo so I can add words like
    # CGLT to approve vscode words from different places. This would be
    # so that I can have the one file for vscode, and define domain specific
    # words in the domain specific sections of the codebase.
in {
    imports = [ 
        (import ./satchel.nix { inherit cgltPath pkgs secrets; })
        (import ./deployments.nix { inherit cgltPath pkgs config secrets; })
        (import ./devops.nix { inherit cgltPath pkgs config; })
        (import ./monorepo.nix { inherit cgltPath pkgs config; })
    ];
}
