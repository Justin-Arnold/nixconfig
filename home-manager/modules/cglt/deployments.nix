{ cgltPath, pkgs, config, secrets, ... }:

{   
    # This defines the root path of the repository and pulls it down.
    home.activation.cloneDeployments = {
        after = ["writeBoundary"];
        before = [];
        data = ''
        PATH="${pkgs.git}/bin:${pkgs.openssh}/bin:$PATH"
        REPO_PATH="${cgltPath}/deployments"
        if [ ! -d "$DEVOPS_PATH" ]; then
            git clone git@github.com:commongoodlt/deployments.git "$REPO_PATH"
        fi
        '';
    };

    home.activation.createPemFiles = {
        after = ["writeBoundary"];
        before = [];
        data = ''
            cd ${cgltPath}/deployments/conf
            cat ${secrets.cglt.pem.pwet} > pwet.pem
            cat ${secrets.cglt.pem.ap-public} > ap-public.pem
            cat ${secrets.cglt.pem.newco} > newco.pem
        '';
    };
}
