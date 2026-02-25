{ ... }: {
  # Whisper STT — speech-to-text for Home Assistant voice assistant
  services.wyoming.faster-whisper.servers."en" = {
    enable = true;
    model = "distil-large-v3";
    language = "en";
    uri = "tcp://0.0.0.0:10300";
    device = "cuda";
  };

  # Piper TTS — text-to-speech for Home Assistant voice assistant
  services.wyoming.piper.servers."en_US-lessac-medium" = {
    enable = true;
    voice = "en_US-lessac-medium";
    uri = "tcp://0.0.0.0:10200";
  };

  networking.firewall.allowedTCPPorts = [ 10300 10200 ];
}
