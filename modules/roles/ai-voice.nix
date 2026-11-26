# Home Assistant's speech, on the CPU beside the model: speech to text on
# 10300 and text to speech on 10200, both over the Wyoming protocol, with no
# authentication, as Home Assistant expects. The GPU is left to the model.
#
# Speech to text is NVIDIA's Parakeet TDT 0.6B v2 (English only), through the
# official Wyoming server's sherpa-onnx backend: about 0.2-0.5 s a command on
# a CPU. Chosen on 26 November 2026 over Qwen3-ASR-1.7B, which makes fewer
# errors but would need onnxruntime built with CUDA here to be fast, and no
# binary cache has that. It replaced Whisper (distil-large-v3, on the GPU).
# How to swap is in Justin's vault, 02. Areas/Homelab/Hosts/inference.md,
# "Speech".
#
# Text to speech is Gradium's Phonon 31M, through Gradium's own server image,
# pinned by digest. It downloads its model (pinned by the release) and the
# voice catalog (pinned below) into a volume on first start, and speaks a reply
# a sentence at a time while Home Assistant is still writing it. Its OpenAI-style
# HTTP API stays on loopback inside the container; only Wyoming is published.
# Voices of your own (downloaded from Gradium Studio, or cloned) go in
# /var/lib/phonon/voices, named <voice>.safetensors. It replaced Piper.
{ ... }:
let
  voicesDir = "/var/lib/phonon/voices";
in
{
  services.wyoming.faster-whisper.servers.parakeet = {
    enable = true;
    uri = "tcp://0.0.0.0:10300";
    device = "cpu";
    sttLibrary = "sherpa";
    # Downloaded from sherpa-onnx's releases on first start.
    model = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8";
    language = "en";
    # Home Assistant is pointed at the address; nothing needs to find it.
    zeroconf.enable = false;
  };

  virtualisation.podman.enable = true;

  virtualisation.oci-containers.containers.phonon = {
    # Phonon 0.7.1, 13 November 2026.
    image = "ghcr.io/gradium-ai/ptts-openai-server:0.7.1@sha256:b4f46fb8bbd2dee326a012da6cc33ceadcbafe29e46b827d0e7b1bb01b1b053d";
    autoStart = true;
    ports = [ "10200:10200" ];
    volumes = [
      "phonon-cache:/home/phonon/.cache/huggingface"
      "${voicesDir}:/voices:ro"
    ];
    environment = {
      PTTS_LANG = "en";
      PTTS_QUANT = "q8";
      PTTS_WYOMING_ADDR = "0.0.0.0:10200";
      PTTS_ADDR = "127.0.0.1:8880";
      PTTS_VOICE_DIR = "/voices";
      PTTS_VOICE_CATALOG = "hf://gradium/phonon-voices@0ee17205f254b5abc43b266c8a0f215565c352f7";
      # Two satellites can speak at once; a third waits for a free slot.
      PTTS_MAX_CONCURRENT_REQUESTS = "2";
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/phonon 0755 root root - -"
    "d ${voicesDir} 0755 root root - -"
  ];

  networking.firewall.allowedTCPPorts = [ 10300 10200 ];
}
