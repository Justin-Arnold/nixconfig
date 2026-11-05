#!/usr/bin/env bash
# Read-only health report for the inference VM. Prints no secret values.
#
#   ssh inference 'sudo bash -s' < scripts/inference/post-install-check.sh
#
# With CANARY set, it also looks for that string everywhere a prompt could
# have been written down, after a test that sent it (it should be nowhere):
#
#   ssh inference "sudo CANARY=$canary bash -s" < scripts/inference/post-install-check.sh
set -u

section() { printf '\n== %s\n' "$1"; }
code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
name=inference.servicestack.xyz
models=/var/lib/inference/models

section "system"
hostname
nixos-version
uptime

section "failed units"
systemctl --failed --no-legend --no-pager || true

section "services"
for unit in llama-server inference-models nginx nvidia-persistenced podman-wyoming-whisper \
  wyoming-piper-en_US-lessac-medium beszel-agent; do
  printf '%-36s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null)"
done
printf 'docker installed: %s, ollama installed: %s (expect no, no)\n' \
  "$(command -v docker >/dev/null && echo yes || echo no)" "$(command -v ollama >/dev/null && echo yes || echo no)"
printf 'nixos-upgrade timer: %s (expect inactive)\n' "$(systemctl is-active nixos-upgrade.timer 2>/dev/null)"

section "gpu (Whisper and llama-server should both be on the card)"
nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader 2>&1
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>&1

section "llama-server"
pid=$(systemctl show -p MainPID --value llama-server)
printf 'up %s, restarts %s, user %s\n' "$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')" \
  "$(systemctl show -p NRestarts --value llama-server)" "$(ps -o user= -p "$pid" 2>/dev/null)"
printf '/health on loopback: %s\n' "$(code http://127.0.0.1:8080/health)"
# /props is only reachable here, on loopback: nginx doesn't serve it.
curl -s --max-time 10 http://127.0.0.1:8080/props \
  | jq -c '{model: .model_alias, slots: .total_slots, n_ctx_per_slot: .default_generation_settings.n_ctx, build: .build_info}' 2>&1
echo "expect slots 4 and n_ctx_per_slot 65536"
echo "model files:"
find "$models" -maxdepth 2 -type f -name '*.gguf' -printf '  %s bytes  %p\n' 2>&1
echo "warnings and errors this boot (last 5):"
journalctl -u llama-server -u inference-models -b --no-pager -o cat -p warning | cut -c1-200 | tail -5

section "nothing kept"
printf 'swap: %s (expect none)\n' "$(swapon --noheadings --show=NAME 2>/dev/null | tr '\n' ' ' | sed 's/ $//' | grep . || echo none)"
printf 'core dumps: %s (expect Storage=none)\n' "$(systemd-analyze cat-config systemd/coredump.conf 2>/dev/null | grep -E '^Storage=' | tail -1)"
printf 'nginx temp files: %s (expect 0)\n' "$(find /var/cache/nginx -type f 2>/dev/null | wc -l)"
if [[ -n ${CANARY:-} ]]; then
  echo "canary $CANARY found in (expect nothing):"
  journalctl -b --no-pager -o cat | grep -cF "$CANARY" | sed 's/^/  journal lines: /'
  grep -rlIF --exclude-dir=models --exclude-dir=containers "$CANARY" /var/log /var/cache /var/lib /tmp /var/tmp 2>/dev/null | sed 's/^/  /'
fi

section "listening sockets (expect 22, 443, 10200, 10300, and nginx's default 80 that the firewall drops; 8080 on 127.0.0.1)"
ss -tlnp | awk 'NR == 1 || /LISTEN/'

section "nginx from this host (127.0.0.1 isn't on the allow-lists: 401 without a key on the API, 403 on /health, 404 elsewhere)"
printf '%-48s %s\n' "POST $name/v1/chat/completions" \
  "$(code -X POST --resolve "$name:443:127.0.0.1" "https://$name/v1/chat/completions")"
for path in /v1/models /health /props /slots /completion /; do
  printf '%-48s %s\n' "$name$path" "$(code --resolve "$name:443:127.0.0.1" "https://$name$path")"
done
printf '%-48s %s (expect 000: no certificate for unknown names)\n' "https://127.0.0.1/" "$(code https://127.0.0.1/)"
echo "requests by client today:"
awk -v d="$(date +%Y-%m-%d)" 'index($1, d) == 1 {sub(/^client=/, "", $3); print $3 == "" ? "(no key)" : $3}' /var/log/nginx/inference.log 2>/dev/null \
  | sort | uniq -c | sed 's/^/  /'

# The host has no openssl; curl's handshake log shows the served certificate.
# Until the first order succeeds, nginx serves a self-signed placeholder.
section "tls certificate"
curl -skv -o /dev/null --max-time 10 --resolve "$name:443:127.0.0.1" "https://$name/health" 2>&1 \
  | grep -E '^\* +(subject|issuer|expire date):'
systemctl show -p ActiveState -p Result "acme-order-renew-$name.service"
