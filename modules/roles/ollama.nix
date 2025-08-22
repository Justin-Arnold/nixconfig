{ config, pkgs, ... }:
let ollamaPkg = pkgs.ollama.override { cudaSupport = true; };
in {
  hardware.graphics.enable = true;
  services.xserver.videoDrivers = [ "nvidia" ];

  boot.blacklistedKernelModules = [ "nouveau" "nvidiafb" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;  # Critical for headless
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    open = false;
    nvidiaPersistenced = true;
    forceFullCompositionPipeline = true;
    prime.offload.enable = false;
  };

  boot.kernelParams = [
    "nvidia-drm.modeset=1"
    "nvidia.NVreg_PreserveVideoMemoryAllocations=1"
    "nvidia.NVreg_TemporaryFilePath=/var/tmp"
  ];

  boot.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];

  environment.systemPackages = with pkgs; [
    pciutils
    nvtopPackages.full
    cudaPackages.cudatoolkit
    # cudaPackages.cuda_samples  # For testing
  ];

  services.ollama = {
    enable = true;
    acceleration = "cuda";
    host = "0.0.0.0";
    port = 11434;
    environmentVariables = {
      OLLAMA_NUM_GPU = "1";
      CUDA_HOME = "${pkgs.cudaPackages.cudatoolkit}";
    };
  };

  users.users.justin.extraGroups = [ "video" "render" ];
  networking.firewall.allowedTCPPorts = [ 11434 ];
}