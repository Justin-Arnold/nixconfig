{ pkgs, ... }:
let
  proj = "infra/ansible/checkmk";
in {
  home.file."${proj}/ansible.cfg".text = ''
    [defaults]
    inventory = ./inventory.ini
    host_key_checking = False
    interpreter_python = auto_silent
    timeout = 30
    retry_files_enabled = False
    [ssh_connection]
    pipelining = True
    ssh_args = -o ControlMaster=auto -o ControlPersist=60s
  '';
  #todo centralize the ip and user - also do with terraform steps
  home.file."${proj}/inventory.ini".text = ''
    [checkmk]
    10.0.0.68 ansible_user=justin
  '';
  home.file."${proj}/site.yml".text = ''
    # site.yml
    - name: Bootstrap NixOS host (Checkmk)
      hosts: checkmk
      gather_facts: false
      vars:
        flake_attr: "checkmk"
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
            sudo mkdir -p "$(dirname "{{ sops_age_key_dest }}")"
            sudo chown justin:users "$(dirname "{{ sops_age_key_dest }}")"
            sudo chmod 700 "$(dirname "{{ sops_age_key_dest }}")"

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
  '';
  programs.zsh.shellAliases = {
    ans-checkmk = "cd ~/${proj} && ansible-playbook site.yml";
  };
}