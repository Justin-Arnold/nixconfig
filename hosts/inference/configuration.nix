# inference: the lab's GPU host, a NixOS VM on proxmox2 with the RTX 3090
# passed through (infra/terranix/hosts/inference.nix). It serves one model to
# every client as `local`, through llama-server on loopback
# (modules/roles/inference.nix, models.nix) behind nginx with a key per
# client (endpoints.nix), plus Home Assistant's speech to text (Whisper, on
# the GPU) and text to speech (Piper). It holds no credentials but its own:
# the clients' keys, its certificate's DNS key and the Beszel token. See
# docs/inference/REFERENCE.md.
{ config, lib, pkgs, inputs, sops-nix, ... }:
let
  macMiniKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA80MbGDPmyq9NruBH2oS0vVzFDXSH0oT+YqxrIW89Da hello@justin-arnold.com";

  fw = config.networking.firewall;
  publicTcpPorts = lib.sort lib.lessThan (lib.unique fw.allowedTCPPorts);
  publicUdpPorts = lib.unique fw.allowedUDPPorts;
  interfaceRules = lib.filterAttrs
    (_: i: i.allowedTCPPorts != [ ] || i.allowedUDPPorts != [ ] || i.allowedTCPPortRanges != [ ] || i.allowedUDPPortRanges != [ ])
    fw.interfaces;
  # The NixOS firewall always trusts the loopback interface.
  trustedInterfaces = lib.subtractLists [ "lo" ] fw.trustedInterfaces;
in
{
  imports =
    lib.optional (builtins.pathExists ./hardware-configuration.nix) ./hardware-configuration.nix
    ++ [
      inputs.disko.nixosModules.disko
      ./disko.nix
      ./endpoints.nix
      ./models.nix
      ../../modules/common
      ../../modules/profiles/server.nix
      ../../modules/platforms/nixos
      ../../modules/roles/nvidia-gpu.nix
      ../../modules/roles/inference.nix
      ../../modules/roles/ai-voice.nix
      ../../modules/roles/beszel-agent.nix

      sops-nix.nixosModules.sops
    ];

  systemProfile = {
    hostname = "inference";
    stateVersion = "26.05";
    isServer = true;
  };

  # The Proxmox bootstrap template clones in as scsi0, which the guest sees
  # as /dev/sda.
  boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];

  # The MAC is fixed in Terraform; OPNsense keeps a DHCP reservation for it
  # (10.0.0.63), which Home Assistant's Whisper and Piper settings point at.
  networking.useDHCP = lib.mkDefault true;

  profiles.server = {
    # Only the operator's Mac Mini key; lab controllers are not trusted here.
    authorizedKeys = [ macMiniKey ];
    # Upgrades are deliberate: nix flake update + nix run .#switch.
    autoUpgrade.enable = false;
  };

  # No Home Manager user environment: keeps the closure small and the host
  # independent of user-tool downloads.
  home-manager.users = lib.mkForce { };

  # nixpkgs opens DNS (port 53) on every podman interface by default.
  # Whisper's container is on Podman's default network, which runs no DNS
  # server, so it stays shut and the firewall guard below still holds.
  virtualisation.podman.dns.openFirewall = false;

  services.journald.settings.Journal = {
    SystemMaxUse = "1G";
    MaxRetentionSec = "30day";
  };

  ############################################################
  ## Users and secrets (SOPS, host-scoped key)
  ############################################################
  # justin is key-only; root has a password for the Proxmox console only
  # (SSH root login is off).
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets."root/console-password-hash".path;

  sops = {
    defaultSopsFile = ../../secrets/hosts/inference.yaml;
    # Dedicated host identity, installed by `nix run .#install` with
    # HOST_AGE_KEY_FILE. The operator key is never copied to this host.
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];

    secrets."root/console-password-hash".neededForUsers = true;
  };

  ############################################################
  ## Workloads
  ############################################################
  roles.inference = {
    enable = true;
    # Chosen by scripts/inference/model-test.py on 4 November 2026; the
    # results are in docs/inference/REFERENCE.md.
    active = "qwen3.6-35b-a3b";
  };

  roles.beszelAgent = {
    enable = true;
    tokenSecret = "beszel/agent-token";
  };

  # For scripts/inference/post-install-check.sh.
  environment.systemPackages = [ pkgs.jq ];

  ############################################################
  ## Guards
  ############################################################
  # The exposure policy. .#checks.<system>.inference-exposure-guards breaks
  # each of these and fails unless evaluation refuses it.
  assertions = [
    {
      # SSH, the model over HTTPS, and Home Assistant's Piper (10200) and
      # Whisper (10300).
      assertion = publicTcpPorts == [ 22 443 10200 10300 ];
      message = "inference: public TCP ports must be exactly 22, 443, 10200, 10300 (got ${toString publicTcpPorts}).";
    }
    {
      assertion = publicUdpPorts == [ ];
      message = "inference: no public UDP ports (got ${toString publicUdpPorts}).";
    }
    {
      assertion = interfaceRules == { } && trustedInterfaces == [ ];
      message = "inference: no per-interface firewall openings or trusted interfaces (got ${toString (lib.attrNames interfaceRules ++ trustedInterfaces)}).";
    }
    {
      assertion = !config.virtualisation.docker.enable;
      message = "inference: no Docker; Whisper runs under Podman.";
    }
    {
      assertion = !config.services.ollama.enable;
      message = "inference: Ollama stays off; llama-server is the only model server on the card.";
    }
    {
      assertion = config.swapDevices == [ ] && !config.zramSwap.enable;
      message = "inference: no swap, so prompts in memory are never paged to disk.";
    }
    {
      assertion = (config.systemd.coredump.settings.Coredump.Storage or null) == "none";
      message = "inference: core dumps are never stored; one would hold prompts.";
    }
    {
      assertion = !config.sops.validateSopsFiles || builtins.pathExists config.sops.defaultSopsFile;
      message = ''
        inference: secrets/hosts/inference.yaml doesn't exist yet. Generate the
        host age key, add its recipient to .sops.yaml, create the file with
        sops and `git add` it (docs/inference/REFERENCE.md, "Secrets").
      '';
    }
  ];
}
