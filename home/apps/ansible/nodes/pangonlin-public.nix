{ pkgs, ... }:
let
  proj = "infra/ansible/pangolin-public";
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
    [pangolin]
    pangolin-public ansible_host=5.161.26.162 ansible_user=justin
  '';
  home.file."${proj}/site.yml".text = ''
    # site.yml
    - name: Setup Pangolin Public Server
      hosts: pangolin
      become: yes
      vars:
        pangolin_install_dir: /opt/pangolin
        pangolin_user: pangolin
        
      tasks:
        - name: Update system packages
          apt:
            update_cache: yes
            upgrade: dist

        - name: Install required packages
          apt:
            name:
              - curl
              - wget
              - ufw
              - fail2ban
              - htop
              - git
            state: present

        - name: Configure firewall rules
          ufw:
            rule: allow
            port: "{{ item.port }}"
            proto: "{{ item.proto }}"
          loop:
            - { port: "22", proto: "tcp" }
            - { port: "80", proto: "tcp" }
            - { port: "443", proto: "tcp" }
            - { port: "51820", proto: "udp" }
            - { port: "21820", proto: "udp" }

        - name: Enable firewall
          ufw:
            state: enabled
            policy: deny
            direction: incoming

        - name: Create pangolin system user
          user:
            name: "{{ pangolin_user }}"
            system: yes
            shell: /bin/false
            home: "{{ pangolin_install_dir }}"
            create_home: no

        - name: Create pangolin directory
          file:
            path: "{{ pangolin_install_dir }}"
            state: directory
            owner: "{{ pangolin_user }}"
            group: "{{ pangolin_user }}"
            mode: '0755'

        - name: Download pangolin installer script
          get_url:
            url: https://digpangolin.com/get-installer.sh
            dest: "{{ pangolin_install_dir }}/get-installer.sh"
            mode: '0755'
            owner: "{{ pangolin_user }}"
            group: "{{ pangolin_user }}"

        - name: Run pangolin installer download
          shell: |
            cd {{ pangolin_install_dir }}
            ./get-installer.sh
          args:
            creates: "{{ pangolin_install_dir }}/installer"
          become_user: "{{ pangolin_user }}"

        - name: Run pangolin installer
          shell: |
            cd {{ pangolin_install_dir }}
            sudo ./installer
          args:
            creates: "{{ pangolin_install_dir }}/pangolin"

        - name: Create pangolin systemd service
          template:
            src: pangolin.service.j2
            dest: /etc/systemd/system/pangolin.service
          notify: restart pangolin

        - name: Enable and start pangolin service
          systemd:
            name: pangolin
            enabled: yes
            state: started
            daemon_reload: yes

        - name: Configure fail2ban
          systemd:
            name: fail2ban
            enabled: yes
            state: started

      handlers:
        - name: restart pangolin
          systemd:
            name: pangolin
            state: restarted
            daemon_reload: yes
  '';

  home.file."${proj}/templates/pangolin.service.j2".text = ''
    [Unit]
    Description=Pangolin Tunnel Service
    After=network.target
    Wants=network.target

    [Service]
    Type=simple
    User={{ pangolin_user }}
    Group={{ pangolin_user }}
    WorkingDirectory={{ pangolin_install_dir }}
    ExecStart={{ pangolin_install_dir }}/pangolin
    Restart=always
    RestartSec=5
    StandardOutput=journal
    StandardError=journal

    [Install]
    WantedBy=multi-user.target
  '';
  
  programs.zsh.shellAliases = {
    ans-pangolin = "cd ~/${proj} && ansible-playbook site.yml";
  };
}