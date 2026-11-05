#!/usr/bin/env bash
# Read-only health report for the openclaw VM. Prints no secret values.
#
#   ssh openclaw 'sudo bash -s' < scripts/openclaw/post-install-check.sh
set -u

section() { printf '\n== %s\n' "$1"; }
code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
name=openclaw.servicestack.xyz
state=/var/lib/openclaw

section "system"
hostname
nixos-version
uptime

section "failed units"
systemctl --failed --no-legend --no-pager || true

section "services"
for unit in openclaw-gateway nginx nftables beszel-agent sqlite-backup.timer mnt-openclaw\\x2dbackups.automount; do
  printf '%-36s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null)"
done
printf 'container engine installed: %s (expect no)\n' "$(command -v docker podman >/dev/null && echo yes || echo no)"

section "gateway"
pid=$(systemctl show -p MainPID --value openclaw-gateway)
printf 'up %s, restarts %s, user %s\n' "$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')" \
  "$(systemctl show -p NRestarts --value openclaw-gateway)" "$(ps -o user= -p "$pid" 2>/dev/null)"
printf '/healthz %s, /readyz %s on loopback\n' "$(code http://127.0.0.1:18789/healthz)" "$(code http://127.0.0.1:18789/readyz)"
stat -c '%U:%G %a %n' "$state" "$state/openclaw.json" "$state/workspace/AGENTS.md" 2>&1
stat -L -c '%U:%G %a env file (SOPS)' /run/secrets/rendered/openclaw.env 2>&1
echo "expect openclaw 700 on the state dir, openclaw 400 on the config and AGENTS.md, root 400 on the env file"
echo "errors this boot (last 5):"
journalctl -u openclaw-gateway -b --no-pager -o cat -p warning | cut -c1-200 | tail -5

section "openclaw security audit"
openclaw-admin security audit 2>&1 | cut -c1-200 | head -40

section "models (the concierge's ChatGPT login)"
openclaw-admin models status 2>&1 | cut -c1-200 | head -20

section "devices (paired and pending)"
openclaw-admin devices list 2>&1 | cut -c1-200 | head -20

# Run as the gateway's user, so the LAN attempts are refused on this host and
# never reach their targets.
section "egress (expect Paperclip 200, OpenAI answering, the LAN 000 in 0s)"
nft list chain inet agent-egress output 2>&1 | grep -oE 'meta sk[ug]id .*|Error.*'
for target in https://paperclip.servicestack.xyz/api/health https://api.openai.com/ http://10.0.0.1:3000/ https://10.0.0.153/; do
  printf '%-46s %s\n' "$target" \
    "$(runuser -u openclaw -- curl -sk -o /dev/null -w '%{http_code} in %{time_total}s' --max-time 5 "$target")"
done
printf 'refused so far: %s\n' "$(nft list chain inet agent-egress refuse 2>&1 | grep -oE 'packets [0-9]+')"

section "listening sockets (expect 22, 80, 443 public, plus rpcbind for the NFS mount and LLMNR that the firewall drops; 18789 on loopback)"
ss -tlnp | awk 'NR == 1 || /LISTEN/'

section "nginx from this host (127.0.0.1 isn't on the allow-lists, so 403)"
for path in /readyz /; do
  printf '%-40s %s\n' "$name$path" "$(code --resolve "$name:443:127.0.0.1" "https://$name$path")"
done
printf '%-40s %s (expect 000: no certificate for unknown names)\n' "https://127.0.0.1/" "$(code https://127.0.0.1/)"

# The host has no openssl; curl's handshake log shows the served certificate.
# Until the first order succeeds, nginx serves a self-signed placeholder.
section "tls certificate"
curl -skv -o /dev/null --max-time 10 --resolve "$name:443:127.0.0.1" "https://$name/" 2>&1 \
  | grep -E '^\* +(subject|issuer|expire date):'
systemctl show -p ActiveState -p Result "acme-order-renew-$name.service"

section "backups"
systemctl list-timers --no-pager sqlite-backup.timer | head -2
journalctl -u sqlite-backup --no-pager -o cat -n 4
sqlite-backup list 2>&1 | head -3
