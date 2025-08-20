{ config, pkgs, ... }:
let ollamaPkg = pkgs.ollama.override { cudaSupport = true; };
in {
  hardware.opengl.enable = true;
  hardware.nvidia = {
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
  services.nvidia-persistenced.enable = true;

  systemd.services.ollama = {
    description = "Ollama";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${ollamaPkg}/bin/ollama serve";
      Environment = [ "OLLAMA_HOST=0.0.0.0:11434" ];
      Restart = "always"; RestartSec = 2;
    };
  };
  networking.firewall.allowedTCPPorts = [ 11434 ];
}