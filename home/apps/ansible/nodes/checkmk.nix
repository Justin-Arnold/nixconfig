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
    10.0.0.68 ansible_user=justin ansible_python_interpreter=/run/current-system/sw/bin/python3
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
        - name: Wait for SSH
          wait_for_connection:
            timeout: 300

        - name: Ensure age dir exists with strict perms
          become: true
          ansible.builtin.file:
            path: "{{ sops_age_key_dest | dirname }}"
            state: directory
            owner: justin
            group: users
            mode: '0700'

        - name: Copy age private key from controller
          become: true
          no_log: true  
          ansible.builtin.copy:
            src: "{{ sops_age_key_src }}"
            dest: "{{ sops_age_key_dest }}"
            owner: justin
            group: users
            mode: '0400'

        - name: Switch to your flake
          become: true
          ansible.builtin.command: >
            nixos-rebuild switch
            --flake github:Justin-Arnold/nixconfig#{{ flake_attr }}
            --refresh --no-write-lock-file
  '';

  programs.zsh.shellAliases = {
    ans-checkmk = "cd ~/${proj} && ansible-playbook site.yml";
  };
}