{ pkgs, ... }:
let
  proj = "infra/ansible/nocodb";
in {
  home.file."${proj}/ansible.cfg".text = ''
    [defaults]
    inventory = ./inventory.ini
    host_key_checking = False
    interpreter_python = auto_silent
    timeout = 30
    retry_files_enabled = False
    collections_paths = ~/.ansible/collections
    [ssh_connection]
    pipelining = True
    ssh_args = -o ControlMaster=auto -o ControlPersist=60s -o ForwardAgent=yes -o IdentitiesOnly=no -o PreferredAuthentications=publickey
  '';

  home.file."${proj}/inventory.ini".text = ''
    [nocodb]
    nocodb.host.internal ansible_user=justin ansible_ssh_private_key_file=/home/justin/.ssh/nocodb_host_key
  '';

  home.file."${proj}/setup-ssh.yml".text = ''
    ---
    - name: Setup SSH keys from 1Password Connect
      hosts: localhost
      gather_facts: false
      vars:
        op_connect_host: "http://10.0.0.70:8080"
        op_vault_name: "Lab 0118"
        op_ssh_key_item_name: "ssh-host-nocodb"
        op_connect_token: "{{ lookup('env', 'OP_API_TOKEN') }}"
        ssh_key_path: "/home/justin/.ssh/nocodb_host_key"
      
      tasks:
        - name: Check if SSH key already exists locally
          stat:
            path: "{{ ssh_key_path }}"
          register: ssh_key_exists

        - name: Get SSH key from 1Password if not present locally
          block:
            - name: Get list of vaults from 1Password Connect
              uri:
                url: "{{ op_connect_host }}/v1/vaults"
                method: GET
                headers:
                  Authorization: "Bearer {{ op_connect_token }}"
                  Accept: "application/json"
              register: vaults_response

            - name: Find vault ID for Lab 0118
              set_fact:
                vault_id: "{{ vaults_response.json | selectattr('name', 'equalto', op_vault_name) | map(attribute='id') | first }}"

            - name: Get items from vault
              uri:
                url: "{{ op_connect_host }}/v1/vaults/{{ vault_id }}/items"
                method: GET
                headers:
                  Authorization: "Bearer {{ op_connect_token }}"
                  Accept: "application/json"
              register: items_response

            - name: Find SSH key item ID
              set_fact:
                ssh_key_item_id: "{{ items_response.json | selectattr('title', 'equalto', op_ssh_key_item_name) | map(attribute='id') | first }}"

            - name: Get SSH key details from 1Password Connect
              uri:
                url: "{{ op_connect_host }}/v1/vaults/{{ vault_id }}/items/{{ ssh_key_item_id }}"
                method: GET
                headers:
                  Authorization: "Bearer {{ op_connect_token }}"
                  Accept: "application/json"
              register: ssh_key_response
              no_log: true

            - name: Extract private key from response
              set_fact:
                private_key: "{{ ssh_key_response.json.fields | selectattr('label', 'equalto', 'private key') | map(attribute='value') | first }}"
              no_log: true

            - name: Ensure .ssh directory exists
              file:
                path: "/home/justin/.ssh"
                state: directory
                mode: '0700'

            - name: Save SSH private key to ~/.ssh
              copy:
                content: "{{ private_key }}"
                dest: "{{ ssh_key_path }}"
                mode: '0600'
              no_log: true

            - name: Generate and save public key
              shell: ssh-keygen -y -f "{{ ssh_key_path }}"
              register: public_key_content

            - name: Save public key
              copy:
                content: "{{ public_key_content.stdout }}"
                dest: "{{ ssh_key_path }}.pub"
                mode: '0644'

          when: not ssh_key_exists.stat.exists

        - name: Start SSH agent if not running
          shell: |
            if [ -z "$SSH_AUTH_SOCK" ] || ! ssh-add -l >/dev/null 2>&1; then
              pkill ssh-agent 2>/dev/null || true
              eval $(ssh-agent -s)
              echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" > /tmp/ssh_agent_env
              echo "SSH_AGENT_PID=$SSH_AGENT_PID" >> /tmp/ssh_agent_env
              echo "export SSH_AUTH_SOCK SSH_AGENT_PID" >> /tmp/ssh_agent_env
              echo "Started new SSH agent"
            else
              echo "SSH agent already running"
            fi
          register: ssh_agent_start

        - name: Check if key is already loaded in agent
          shell: source /tmp/ssh_agent_env && ssh-add -l | grep -q "{{ ssh_key_path }}" || echo "not_loaded"
          register: key_in_agent
          failed_when: false

        - name: Add SSH key to agent if not already loaded
          shell: source /tmp/ssh_agent_env && ssh-add "{{ ssh_key_path }}"
          when: "'not_loaded' in key_in_agent.stdout"

        - name: List keys in SSH agent
          shell: source /tmp/ssh_agent_env && ssh-add -l
          register: agent_keys

        - name: Display loaded keys
          debug:
            msg: "SSH agent keys: {{ agent_keys.stdout_lines }}"

        - name: Test SSH connection to target host
          shell: |
            source /tmp/ssh_agent_env
            ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
                -o IdentitiesOnly=no -o PreferredAuthentications=publickey \
                justin@nocodb.host.internal echo "SSH connection successful"
          register: ssh_test
          failed_when: false

        - name: Display SSH test result
          debug:
            msg: |
              SSH test result: {{ ssh_test.rc }}
              Output: {{ ssh_test.stdout }}
              Error: {{ ssh_test.stderr }}
  '';

  home.file."${proj}/site.yml".text = ''
    ---
    # Main playbook that first sets up SSH keys, then deploys
    - import_playbook: setup-ssh.yml

    - name: Bootstrap NixOS host (NoCoDB)
      hosts: nocodb
      gather_facts: false
      vars:
        flake_attr: "nocodb"
        sops_age_key_src: "~/.config/sops/age/keys.txt"
        sops_age_key_dest: "/home/justin/.config/sops/age/keys.txt"
      
      tasks:
        - name: Wait for SSH (using raw)
          raw: echo "SSH connection ready"
          register: connection_test
          until: connection_test is succeeded
          retries: 30
          delay: 10

        - name: Ensure age dir exists with strict perms
          raw: |
            sudo -u justin mkdir -p "{{ sops_age_key_dest | dirname }}"
            sudo chmod 700 "{{ sops_age_key_dest | dirname }}"

        - name: Copy age private key from controller
          raw: |
            # Use base64 to safely transfer the file
            echo '{{ lookup('file', sops_age_key_src) | b64encode }}' | base64 -d | sudo tee "{{ sops_age_key_dest }}" > /dev/null
            sudo chown justin:users "{{ sops_age_key_dest }}"
            sudo chmod 400 "{{ sops_age_key_dest }}"
          no_log: true

        - name: Switch to your flake (this will install Python and other packages)
          raw: |
            sudo nixos-rebuild switch \
              --flake github:Justin-Arnold/nixconfig#{{ flake_attr }} \
              --refresh --no-write-lock-file

        - name: Gather facts now that system is configured
          setup:

        - name: Verify system configuration
          debug:
            msg: "NixOS system successfully bootstrapped with flake {{ flake_attr }}"

        - name: Verify NoCoDB service status
          raw: systemctl status nocodb || true
          register: nocodb_status

        - name: Display NoCoDB status
          debug:
            var: nocodb_status.stdout_lines
  '';

  # Create a wrapper script that sets up the environment
  home.file."${proj}/run-ansible.sh" = {
    text = ''
      #!/usr/bin/env bash
      set -e

      # Check if OP_API_TOKEN is set
      if [ -z "$OP_API_TOKEN" ]; then
          echo "Error: OP_API_TOKEN environment variable is not set"
          echo "Please run: export OP_API_TOKEN=your-connect-token"
          exit 1
      fi

      # Check if 1Password Connect is reachable
      if ! curl -s -f -H "Authorization: Bearer $OP_API_TOKEN" http://10.0.0.70:8080/health > /dev/null; then
          echo "Error: Cannot reach 1Password Connect server at http://10.0.0.70:8080"
          echo "Please ensure the server is running and the token is valid"
          exit 1
      fi

      # Source SSH agent environment if it exists
      if [ -f /tmp/ssh_agent_env ]; then
          source /tmp/ssh_agent_env
          export SSH_AUTH_SOCK SSH_AGENT_PID
      fi

      # Run the playbook
      cd ~/${proj}
      ansible-playbook site.yml "$@"
    '';
    executable = true;  # This makes it executable without chmod
  };

  programs.zsh.shellAliases = {
    ans-nocodb = "cd ~/${proj} && ./run-ansible.sh";
    ans-nocodb-check = "cd ~/${proj} && ./run-ansible.sh --check";
    ans-nocodb-setup = "cd ~/${proj} && ansible-playbook setup-ssh.yml";
  };

  # Environment setup for 1Password
  programs.zsh.initExtra = ''
    # 1Password Connect helper function
    op-connect-test() {
      if [ -z "$OP_API_TOKEN" ]; then
        echo "OP_API_TOKEN not set. Please set it first."
        return 1
      fi
      
      echo "Testing 1Password Connect..."
      curl -s -H "Authorization: Bearer $OP_API_TOKEN" \
           http://10.0.0.70:8080/health | jq '.'
    }

    # Quick token setup (you'll need to replace with your actual token)
    op-set-token() {
      if [ -n "$1" ]; then
        export OP_API_TOKEN="$1"
        echo "OP_API_TOKEN set"
      else
        echo "Usage: op-set-token <your-connect-token>"
      fi
    }
  '';
}