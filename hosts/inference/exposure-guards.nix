# Each case breaks the inference host's exposure policy (configuration.nix),
# and evaluating the example (eval-test.nix) with it must fail. flake/checks.nix
# runs them as .#checks.<system>.inference-exposure-guards.
{ lib, example }:
let
  vhost = "inference.servicestack.xyz";
  loc = path: extraConfig: { services.nginx.virtualHosts.${vhost}.locations.${path}.extraConfig = lib.mkForce extraConfig; };
  model = files: { roles.inference = { models.unpinned = { inherit files; }; active = lib.mkForce "unpinned"; }; };
  gptOss = lib.head example.config.roles.inference.models.gpt-oss-20b.files;
in
{
  extra-public-tcp-port = { networking.firewall.allowedTCPPorts = [ 8080 ]; };
  http-port = { networking.firewall.allowedTCPPorts = [ 80 ]; };
  extra-public-udp-port = { networking.firewall.allowedUDPPorts = [ 5353 ]; };
  interface-opening = { networking.firewall.interfaces.ens18.allowedTCPPorts = [ 8080 ]; };
  trusted-interface = { networking.firewall.trustedInterfaces = [ "ens18" ]; };
  docker-enabled = { virtualisation.docker.enable = true; };
  ollama-enabled = { services.ollama.enable = true; };
  swap-added = { swapDevices = [ { device = "/swapfile"; size = 1024; } ]; };
  zram-added = { zramSwap.enable = true; };
  coredumps-stored = { systemd.coredump.settings.Coredump.Storage = lib.mkForce "external"; };
  one-slot = { roles.inference.parallel = lib.mkForce 1; };
  verbose-logging = { roles.inference.extraFlags = [ "--verbose" ]; };
  prompt-logging = { roles.inference.extraFlags = [ "--verbose-prompt" ]; };
  slots-endpoint = { roles.inference.extraFlags = [ "--slots" ]; };
  props-endpoint = { roles.inference.extraFlags = [ "--props" ]; };
  slot-files = { roles.inference.extraFlags = [ "--slot-save-path" "/var/lib/inference/slots" ]; };
  web-ui = { roles.inference.extraFlags = [ "--ui" ]; };
  server-on-lan = { roles.inference.extraFlags = [ "--host" "0.0.0.0" ]; };
  unified-kv = { roles.inference.extraFlags = [ "--kv-unified" ]; };
  model-from-main = model [ (gptOss // { url = "https://huggingface.co/ggml-org/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-mxfp4.gguf"; }) ];
  model-without-hash = model [ (gptOss // { sha256 = ""; }) ];
  model-off-huggingface = model [ (gptOss // { url = "https://example.com/gpt-oss-20b-mxfp4.gguf"; }) ];
  active-model-missing = { roles.inference.active = lib.mkForce "nonexistent"; };
  inactive-model-logs-prompts = { roles.inference.models.spare = { files = [ gptOss ]; extraFlags = [ "--verbose-prompt" ]; }; };
  extra-vhost = { services.nginx.virtualHosts."other.servicestack.xyz".locations."/".proxyPass = "http://127.0.0.1:8080"; };
  extra-location = { services.nginx.virtualHosts.${vhost}.locations."/completion".proxyPass = "http://127.0.0.1:8080"; };
  catch-all-proxied = { services.nginx.virtualHosts.${vhost}.locations."/".proxyPass = "http://127.0.0.1:8080"; };
  catch-all-serves-files = { services.nginx.virtualHosts.${vhost}.locations."/".root = "/var/lib/inference"; };
  props-location = { services.nginx.virtualHosts.${vhost}.locations."= /props".proxyPass = "http://127.0.0.1:8080"; };
  location-open-to-all = loc "= /v1/models" ''proxy_set_header Authorization "";'';
  newt-allowed = loc "= /health" ''allow 10.0.0.0/24; deny all; proxy_set_header Authorization "";'';
  key-passed-on = loc "= /health" "deny 10.0.0.72; allow 10.0.0.0/24; deny all;";
  no-key-check = loc "= /v1/chat/completions" ''deny 10.0.0.72; allow 10.0.0.0/24; deny all; proxy_set_header Authorization "";'';
  bodies-to-disk = { services.nginx.virtualHosts.${vhost}.extraConfig = lib.mkForce "client_max_body_size 8m;"; };
  http-also = { services.nginx.virtualHosts.${vhost}.addSSL = true; };
  key-in-store = { services.nginx.appendHttpConfig = ''map $http_authorization $x { "Bearer 0123456789abcdef" agents; }''; };
  sops-file-missing = { sops.validateSopsFiles = lib.mkOverride 40 true; };
  beszel-agent-listening = { services.beszel.agent.openFirewall = true; };
}
