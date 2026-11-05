# The NVIDIA card passed through to this VM (the RTX 3090), headless: the
# proprietary driver, its kernel modules, and nvidia-persistenced so the card
# stays initialised between programs.
{ config, pkgs, ... }:
{
  hardware.graphics.enable = true;
  # Selects the driver; it doesn't start an X server.
  services.xserver.videoDrivers = [ "nvidia" ];
  boot.blacklistedKernelModules = [ "nouveau" "nvidiafb" ];

  hardware.nvidia = {
    modesetting.enable = true;
    # Needed headless, or the card can stay in a high power state.
    powerManagement.enable = true;
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

  environment.systemPackages = [ pkgs.pciutils pkgs.nvtopPackages.full ];

  users.users.justin.extraGroups = [ "video" "render" ];
}
