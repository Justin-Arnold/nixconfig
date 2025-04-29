{ cgltPath, pkgs, config, secrets, ... }:

let
  nodePkgs = import ../node-eol-versions.nix;
in {
  home.packages = [
    # Dependencies for this file
    pkgs.jq
  ];

  home.file."${cgltPath}/deployments/.envrc".text = ''
    PATH_add ${nodePkgs.nodejs-16}/bin
    export NODE_OPTIONS="--openssl-legacy-provider"
  '';

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

  home.activation.updateJsonConfig = {
    after = ["writeBoundary" "cloneDeployments"];
    before = [];
    data = ''
      PATH="${pkgs.jq}/bin:$PATH"
      CONFIG_FILE="${cgltPath}/deployments/project_directory.json"
      CURRENT_USER="$USER"

      if [ -f "$CONFIG_FILE" ]; then
        TEMP_FILE=$(mktemp)
        
        jq '.["satchel-local"].DOCROOT = "/Users/${config.home.username}/${cgltPath}/satchel/" |
            .["satchel-local"].NPM_RUN_DIR = "/Users/${config.home.username}/${cgltPath}/satchel/" |
            .["satchel-gaprd"].SERVER_KEY_FILE = "" |
            .["satchel-ap"].SERVER_KEY_FILE = " -e \"ssh -i ap-satchel.pem\" " |
            .["satchel-mt"].HOST_URL = "https://mt-satchel.commongoodlt.com"' \
            "$CONFIG_FILE" > "$TEMP_FILE"

        if [ $? -eq 0 ]; then
          mv "$TEMP_FILE" "$CONFIG_FILE"
          echo "Successfully updated JSON configuration"
        else
          echo "Error updating JSON configuration"
          rm "$TEMP_FILE"
          exit 1
        fi
      else
        echo "Config file not found at $CONFIG_FILE"
        exit 1
      fi
    '';
  };
  
  home.activation.createPemFiles = {
    after = ["writeBoundary" "cloneDeployments"];
    before = [];
    data = ''
      create_or_update_pem() {
        local content="$1"
        local file_path="$2"
        local dir_path="$(dirname "$file_path")"

        # Create directory if it doesn't exist
        mkdir -p "$dir_path"

        # Check if file exists and has correct permissions
        if [ ! -f "$file_path" ] || [ "$(stat -c %a "$file_path")" != "400" ]; then
          echo "Creating or updating $file_path"
          echo "$content" > "$file_path"
          chmod 400 "$file_path"
        else
          # File exists and has correct permissions, check if content needs updating
          if ! echo "$content" | cmp -s - "$file_path"; then
            echo "Updating content of $file_path"
            echo "$content" > "$file_path"
          fi
        fi
      }

      create_or_update_pem '${secrets.cglt.pem.pwet}' "${cgltPath}/deployments/conf/pwet.pem"
      create_or_update_pem '${secrets.cglt.pem.ap-satchel}' "${cgltPath}/deployments/conf/ap-satchel.pem"
      create_or_update_pem '${secrets.cglt.pem.newco}' "${cgltPath}/deployments/conf/newco.pem"
    '';
  };

  programs.zsh = {
    shellAliases = {
      satchel-deploy = "smartDeploy";
    };

    initExtra = ''
      smartDeploy() {
        # Store the current directory
        local ORIGINAL_DIR=$(pwd)
        
        # Change to the deployments directory
        cd "${cgltPath}/deployments" || {
          echo "Error: Could not change to deployments directory"
          return 1
        }
        
        direnv allow
        eval "$(direnv export zsh)"

        # Declare and populate groups
        typeset -A DEPLOY_GROUPS
        DEPLOY_GROUPS["All Instances"]="satchel-ref satchel-alabama satchel-ap satchel-appub satchel-azed satchel-caselabs satchel-cn2 satchel-carnegie satchel-commons satchel-cps satchel-edsby satchel-frogstreet satchel-mt satchel-nc satchel-sas satchel-sc satchel-wi satchel-gaprd satchel-idaho satchel-rosetta satchel-wida"
        DEPLOY_GROUPS["All Instances (without AP Pub)"]="satchel-ref satchel-alabama satchel-ap satchel-azed satchel-caselabs satchel-cn2 satchel-carnegie satchel-commons satchel-cps satchel-edsby satchel-frogstreet satchel-mt satchel-nc satchel-sas satchel-sc satchel-wi satchel-gaprd satchel-idaho satchel-rosetta satchel-wida"
        DEPLOY_GROUPS["All Instances (without Georgia or AP Pub)"]="satchel-ref satchel-alabama satchel-ap satchel-azed satchel-caselabs satchel-cn2 satchel-carnegie satchel-commons satchel-cps satchel-edsby satchel-frogstreet satchel-mt satchel-nc satchel-sas satchel-sc satchel-wi satchel-idaho satchel-rosetta satchel-wida"
        
        # All available instances
        DEPLOY_INSTANCES=(
          satchel-local
          satchel-ref
          satchel-alabama
          satchel-ap
          satchel-appub
          satchel-azed
          satchel-caselabs
          satchel-cn2
          satchel-carnegie
          satchel-commons
          satchel-cps
          satchel-edsby
          satchel-frogstreet
          satchel-mt
          satchel-nc
          satchel-sas
          satchel-sc
          satchel-wi
          satchel-gaprd
          satchel-idaho
          satchel-rosetta
          satchel-wida
        )

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

        # Generate selection menu
        local GROUP_SELECTION=$(
          (
            echo "Custom Selection"
            print -l "''${(@k)DEPLOY_GROUPS}"
          ) | fzf-tmux -p --header="Select a predefined group or custom selection" --no-multi
        )

        local INSTANCES_TO_DEPLOY=""
        
        if [[ $GROUP_SELECTION == "Custom Selection" ]]; then
          # If custom, allow multi-select from all instances
          INSTANCES_TO_DEPLOY=$(print -l "''${DEPLOY_INSTANCES[@]}" | \
            fzf-tmux -p --header="Select instances to deploy (TAB to multi-select)" --multi | \
            tr '\n' ' ')
        else
          # Use the predefined group
          INSTANCES_TO_DEPLOY="''${DEPLOY_GROUPS[$GROUP_SELECTION]}"
        fi

        # Construct and execute the deploy command
        local CMD="python3 deploy.py"
        [[ $BUILD == true ]] && CMD="$CMD --build"
        CMD="$CMD $ARGS $INSTANCES_TO_DEPLOY"

        # Show the command that will be executed
        echo "Executing: $CMD"
        eval $CMD
      }
    '';
  };
}
