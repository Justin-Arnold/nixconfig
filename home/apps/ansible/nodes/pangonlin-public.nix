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

  home.file."${proj}/inventory.ini".text = ''
    [pangolin]
    pangolin-public ansible_host=pangolin-public.host.internal ansible_user=root
  '';

  home.file."${proj}/site.yml".text = ''
    ---
    - name: Setup Pangolin Public Server
      hosts: pangolin
      vars:
        pangolin_install_dir: /opt/pangolin
        pangolin_user: pangolin
        # Configuration variables - customize these for your setup
        pangolin_base_domain: "servicestack.xyz"
        pangolin_dashboard_domain: "tunnel.servicestack.xyz"
        pangolin_letsencrypt_email: "hello@justin-arnold.com"
        pangolin_install_gerbil: "yes"
        pangolin_enable_smtp: "no"
        pangolin_install_crowdsec: "no"
        
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
              - expect
              - docker.io
              - docker-compose-v2
            state: present

        - name: Start and enable Docker
          systemd:
            name: docker
            enabled: yes
            state: started

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
            groups: docker

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
        
        - name: Check if docker-compose.yml exists
          stat:
            path: "{{ pangolin_install_dir }}/docker-compose.yml"
          register: pangolin_compose

        - name: Stop existing Pangolin containers if running
          shell: cd {{ pangolin_install_dir }} && docker compose down
          ignore_errors: yes
          when: pangolin_compose.stat.exists

        - name: Run pangolin installer interactively
          expect:
            command: sudo ./installer
            chdir: "{{ pangolin_install_dir }}"
            responses:
              'Enter your base domain.*': "{{ pangolin_base_domain }}"
              'Enter the domain for the Pangolin dashboard.*': "{{ pangolin_dashboard_domain }}"
              'Enter email for Let.*s Encrypt certificates.*': "{{ pangolin_letsencrypt_email }}"
              'Do you want to use Gerbil.*': "{{ pangolin_install_gerbil }}"
              'Enable email functionality.*SMTP.*': "{{ pangolin_enable_smtp }}"
              'Is your server IPv6 capable.*': "yes"
              'Do you want to download the MaxMind GeoLite2 database.*': "yes"
              'install CrowdSec.*': "{{ pangolin_install_crowdsec }}"
              'Would you like to install and start the containers.*': "yes"
              'Would you like to run Pangolin as Docker or Podman containers.*': "docker"
                      
            timeout: 300
            echo: yes
          args:
            creates: "{{ pangolin_install_dir }}/docker-compose.yml"

        - name: Verify pangolin installation
          stat:
            path: "{{ pangolin_install_dir }}/docker-compose.yml"
          register: pangolin_compose

        - name: Display installation status
          debug:
            msg: "Pangolin installation {{ 'completed successfully' if pangolin_compose.stat.exists else 'failed' }}"

        - name: Configure fail2ban
          systemd:
            name: fail2ban
            enabled: yes
            state: started

        - name: Ensure Pangolin containers are running
          shell: cd {{ pangolin_install_dir }} && docker compose up -d
          when: pangolin_compose.stat.exists
          register: compose_result
          changed_when: "'Started' in compose_result.stdout or 'Created' in compose_result.stdout"
  '';

  programs.zsh.shellAliases = {
    ans-pangolin-public = "cd ~/${proj} && ansible-playbook site.yml";
  };
}