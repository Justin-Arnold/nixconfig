{ pkgs, ... }:

{
  # Enable Podman with NVIDIA CDI support
  virtualisation.podman.enable = true;
  hardware.nvidia-container-toolkit.enable = true;

  # Whisper STT — GPU-accelerated via LinuxServer.io container (CUDA baked in)
  virtualisation.oci-containers.containers.wyoming-whisper = {
    image = "lscr.io/linuxserver/faster-whisper:gpu";
    autoStart = true;
    ports = [ "10300:10300" ];
    volumes = [ "whisper-data:/config" ];
    environment = {
      PUID = "1000";
      PGID = "1000";
      TZ = "America/New_York";
      WHISPER_MODEL = "distil-large-v3";
      WHISPER_LANG = "en";
      WHISPER_BEAM = "5";
    };
    extraOptions = [
      "--device=nvidia.com/gpu=all"
    ];
  };

  # Piper TTS — text-to-speech for Home Assistant voice assistant
  services.wyoming.piper.servers."en_US-lessac-medium" = {
    enable = true;
    voice = "en_US-lessac-medium";
    uri = "tcp://0.0.0.0:10200";
  };

  networking.firewall.allowedTCPPorts = [ 10300 10200 ];
}