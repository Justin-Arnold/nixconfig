{ cgltPath, pkgs, ... }:

{   
    # This defines the root path of the repository and pulls it down.
    home.activation.cloneDevops = {
        after = ["writeBoundary"];
        before = [];
        data = ''
        PATH="${pkgs.git}/bin:${pkgs.openssh}/bin:$PATH"
        DEVOPS_PATH="${cgltPath}/devops"
        if [ ! -d "$DEVOPS_PATH" ]; then
            git clone git@github.com:commongoodlt/devops.git "$DEVOPS_PATH"
            # Optional: remove unneeded directories
            cd "$DEVOPS_PATH" && rm -rf docker-sparkl docker_henry
        fi
        '';
    };
}
