{ lib, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    ansible # Configuration management tool
    ansible-lint # Linting tool for Ansible playbooks
    rsync # File transfer tool
    python3 # Python is often used with Ansible
    jq # JSON processor, useful for parsing Ansible output
  ];
  
  # Lock down SSH a bit (base likely enables ssh already)
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  # Opinionated, fast defaults for Ansible
  environment.etc."ansible/ansible.cfg".text = ''
  [defaults]
  inventory = /etc/ansible/inventory.ini
  host_key_checking = False
  forks = 20
  stdout_callback = yaml
  interpreter_python = auto_silent
  timeout = 30
  callback_enabled = timer, profile_tasks
  nocows = True

  [ssh_connection]
  pipelining = True
  control_master = auto
  control_path = ~/.ssh/ansible-%%h-%%p-%%r
  control_persist = 60s
  '';

  # Seed inventory (edit as you add hosts)
  environment.etc."ansible/inventory.ini".text = ''
  [controllers]
  ansible-controller ansible_host=10.0.0.41

  [all:vars]
  ansible_user=justin
  ansible_ssh_private_key_file=~/.ssh/id_ed25519
  '';

  # Wheel is already NOPASSWD in your base; keep it that way for Ansible sudo.
  security.sudo.wheelNeedsPassword = false;
}