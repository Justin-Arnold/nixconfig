{ config, pkgs, ... }:
let ollamaPkg = pkgs.ollama.override { cudaSupport = true; };
in {
  hardware.graphics.enable = true;

  hardware.nvidia = {
    modesetting.enable = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    cudaSupport = true;          # pulls in CUDA userspace
    open = false;                # proprietary driver (best for 3090 + CUDA)
    nvidiaPersistenced = true;   # keep the GPU initialized between runs
  };

  services.nvidia-persistenced.enable = true;

  environment.systemPackages = with pkgs; [
    pciutils           # lspci
    nvtopPackages.full # nvtop
    nvidia-smi         # comes via driver; explicit is fine
    cudaPackages.cudatoolkit
  ];

  # First-class Ollama service (uses a dedicated user in the right groups)
  services.ollama = {
    enable = true;
    acceleration = "cuda";       # <- makes it link against CUDA
    host = "0.0.0.0";            # listen on all interfaces
    port = 11434;
    # environmentVariables = { OLLAMA_NUM_GPU = "1"; }; # optional
  };
  
  networking.firewall.allowedTCPPorts = [ 11434 ];
}