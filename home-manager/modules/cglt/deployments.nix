{ cgltPath, pkgs, config, secrets, ... }:

{   
  # This defines the root path of the repository and pulls it down.
  home.activation.cloneDeployments = {
    after = ["writeBoundary"];
    before = [];
    data = ''
    PATH="${pkgs.git}/bin:${pkgs.openssh}/bin:$PATH"
    REPO_PATH="${cgltPath}/deployments"
    if [ ! -d "$REPO_PATH" ]; then
      git clone git@github.com:commongoodlt/deployments.git "$REPO_PATH"
    fi
    '';
  };

  home.activation.createPemFiles = {
    after = ["writeBoundary"];
    before = [];
    data = ''
      echo '${secrets.cglt.pem.pwet}' > "${cgltPath}/deployments/conf/pwet.pem"
      chmod 400 "${cgltPath}/deployments/conf/pwet.pem"
      echo '${secrets.cglt.pem.ap-satchel}' > "${cgltPath}/deployments/conf/ap-satchel.pem"
      chmod 400 "${cgltPath}/deployments/conf/ap-satchel.pem"
      echo '${secrets.cglt.pem.newco}' > "${cgltPath}/deployments/conf/newco.pem"
      chmod 400 "${cgltPath}/deployments/conf/newco.pem"
    '';
  };

  programs.zsh = {
    shellAliases = {
      satchel-deploy = "smartDeploy";
    };

    initExtra = ''
      # Predefined groups - Add your common deployment groups here
      declare -A DEPLOY_GROUPS=(
        ["frontend"]="satchel-ap satchel-commons"
        ["education"]="satchel-frogstreet satchel-learning"
        ["all_services"]="satchel-ap satchel-commons satchel-frogstreet satchel-learning satchel-auth"
      )

      # All available instances - Add all your instances here
      DEPLOY_INSTANCES=(
        "satchel-ap"
        "satchel-commons"
        "satchel-frogstreet"
        "satchel-learning"
        "satchel-auth"
        # Add more instances...
      )

      smartDeploy() {
        # Process flags
        local BUILD=false
        local ARGS=""
        
        while [[ $# -gt 0 ]]; do
          case $1 in
            --build)
              BUILD=true
              shift
              ;;
            --doit|--finish)
              ARGS="$ARGS $1"
              shift
              ;;
            *)
              shift
              ;;
          esac
        done

        # First, select from predefined groups or custom
        local GROUP_SELECTION=$(printf "Custom Selection\n%s" "$(printf "%s\n" "${!DEPLOY_GROUPS[@]}")" | \
          fzf-tmux -p --header="Select a predefined group or custom selection" --no-multi)

        local INSTANCES_TO_DEPLOY=""
        
        if [[ $GROUP_SELECTION == "Custom Selection" ]]; then
          # If custom, allow multi-select from all instances
          INSTANCES_TO_DEPLOY=$(printf "%s\n" "${DEPLOY_INSTANCES[@]}" | \
            fzf-tmux -p --header="Select instances to deploy (TAB to multi-select)" --multi | \
            tr '\n' ' ')
        else
          # Use the predefined group
          INSTANCES_TO_DEPLOY="${DEPLOY_GROUPS[$GROUP_SELECTION]}"
        fi

        # Construct and execute the deploy command
        local CMD="python deploy.py"
        [[ $BUILD == true ]] && CMD="$CMD --build"
        CMD="$CMD $ARGS $INSTANCES_TO_DEPLOY"

        # Show the command that will be executed
        echo "Executing: $CMD"
        eval $CMD
      }
    '';
  };
}
