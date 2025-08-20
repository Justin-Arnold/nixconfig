{ pkgs, ... }: {
  ############################################################
  ## Network Configuration
  ############################################################
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [
    22 # SSH
  ];
  networking.useNetworkd = true; 

  ############################################################
  ## User Configuration
  ############################################################
  users.users.justin = {
    isNormalUser = true; 
    shell = pkgs.zsh;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Mac Mini
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com"
    ];
  };
  security.sudo.wheelNeedsPassword = false;

  ############################################################
  ## Nix
  ############################################################
  nix.settings.trusted-users = [ "justin" ];

  ############################################################
  ## System Packages
  ############################################################
  environment.systemPackages = with pkgs; [
    curl    # for fetching resources
    wget    # for downloading files
    htop    # for system monitoring
    jq      # for JSON processing
    ripgrep # for searching text
    fd      # for finding files
    lsof    # for listing open files
  ];

  ############################################################
  ## SSH
  ############################################################
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  ############################################################
  ## Proxmox VM & Cloud-Init
  ############################################################
  services.qemuGuest.enable = true;
  services.cloud-init.enable = true;

  ############################################################
  ## Auto Upgrades
  ############################################################
  system.autoUpgrade = {
    enable = true;
    allowReboot = true;
    dates = "03:30";
  };
  # system.autoUpgrade.flake = "/etc/nixos#hostname"; # Local flake
  # or
  # system.autoUpgrade.flake = "github:your-user/your-flake#hostname"; # Remote flake
}