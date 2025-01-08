{ cgltPath, pkgs, secrets, ... }:

let
    nodePkgs = import ../node-eol-versions.nix;
in {   
    # This defines the root path of the repository and pulls it down.
    home.activation.cloneSatchel = {
        after = ["writeBoundary"];
        before = [];
        data = ''
        PATH="${pkgs.git}/bin:${pkgs.openssh}/bin:$PATH"
        if [ ! -d "${cgltPath}/satchel" ]; then
            git clone git@github.com:commongoodlt/satchel.git "${cgltPath}/satchel"
        fi
        '';
    };
    # This was the original implementation, however, as far as I can tell it
    # creates a readonly copy of the repo in the nix store and then symlinks
    # it to the defined location. This makes sense in retrospect, but that
    # does not really align with the goal of working in the repo. Instead I
    # have opted to use a activation script that clone down the repo if it
    # does not exist. I could see how this approach would be great for
    # something like one of my homelab servers to pull down a repo I am
    # just going to run and not edit.
    # home.file."${cgltPath}/satchel".source = builtins.fetchGit {
    #     url = "git@github.com:commongoodlt/satchel.git";
    #     ref = "main";
    # };
    # home.file."${cgltPath}/satchel/.envrc".text = ''
    #     use nix
    #     layout node ${nodePkgs.nodejs-16}
    # '';
    home.file."${cgltPath}/satchel/.envrc".text = ''
        PATH_add ${nodePkgs.nodejs-16}/bin
    '';

    home.activation.writeNpmrc = {
        after = ["writeBoundary"];
        before = [];
        data = ''
            echo '${secrets.cglt.npm_token}' > "${cgltPath}/satchel/vue-cli/.npmrc"
            chmod 600 "${cgltPath}/satchel/vue-cli/.npmrc"
        '';
    };

    home.activation.writeSparklsaltConfig = {
        after = ["writeBoundary"];
        before = [];
        data = ''
            cat > "${cgltPath}/satchel/src/sparklsalt_config.php" << 'EOF'
            ${secrets.cglt.sparklsalt_config}
            EOF
        '';
    };

    home.activation.writeFilestoreDirectories = {
        after = ["writeBoundary"];
        before = [];
        data = ''
            mkdir -p ${cgltPath}/satchel/src/filestore/{framework_archives,frameworks,frameworks_case_v1p0,frameworks_case_v1p1,images,tmp,vectors}
        '';
    };

    home.activation.writeDatabaseDirectories = {
        after = ["writeBoundary"];
        before = [];
        data = ''
            mkdir -p ${cgltPath}/satchel-db/{data,load} 
            mkdir -p ${cgltPath}/suitcase 
            mkdir -p ${cgltPath}/suitcase-db/{data,load}
        '';
    };

    services.node.versions = {
        node16 = nodePkgs.nodejs-16;
    };
}
