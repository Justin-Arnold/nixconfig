#!/usr/bin/env bash
# Read-only health report for the automation VM. Prints no secret values.
#
#   ssh automation 'sudo bash -s' < scripts/automation/post-install-check.sh
set -u

section() { printf '\n== %s\n' "$1"; }
code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
name=automation.servicestack.xyz

section "system"
hostname
nixos-version
uptime

section "failed units"
systemctl --failed --no-legend --no-pager || true

section "services"
for unit in n8n nginx beszel-agent sqlite-backup.timer mnt-automation\\x2dbackups.automount; do
  printf '%-36s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null)"
done

section "n8n"
printf 'version: %s\n' "$(systemctl show -p ExecStart --value n8n | grep -o 'n8n-[0-9][0-9.]*' | head -1)"
printf 'runs as: %s\n' "$(ps -o user= -p "$(systemctl show -p MainPID --value n8n)" 2>/dev/null)"
printf 'IPAddressAllow: %s\n' "$(systemctl show -p IPAddressAllow --value n8n)"
stat -c '%U:%G %a %n' /var/lib/n8n /var/lib/n8n/.n8n /var/lib/n8n/.n8n/database.sqlite /var/lib/n8n/.encryption-key.sha256 2>&1
printf 'key in the unit environment: %s (expect 0)\n' \
  "$(systemctl show -p Environment --value n8n | tr ' ' '\n' | grep -c '^N8N_ENCRYPTION_KEY=')"
printf '/healthz on loopback: %s\n' "$(code http://127.0.0.1:5678/healthz)"
journalctl -u n8n -b --no-pager -o cat | grep -v 'Python task runner' | tail -5

section "listening sockets (expect 22, 80, 443 public; n8n on 127.0.0.1 only)"
ss -tlnp | awk 'NR == 1 || /LISTEN/'

section "nginx from this host (127.0.0.1 isn't on the allow-lists, so expect 403)"
for path in /webhook/github /healthz /; do
  printf '%-44s %s\n' "$name$path" "$(code --resolve "$name:443:127.0.0.1" "https://$name$path")"
done
printf '%-44s %s (expect 000: no certificate for unknown names)\n' "https://127.0.0.1/" "$(code https://127.0.0.1/)"

# The host has no openssl; curl's handshake log shows the served certificate.
# Until the first order succeeds, nginx serves a self-signed placeholder.
section "tls certificate"
curl -skv -o /dev/null --max-time 10 --resolve "$name:443:127.0.0.1" "https://$name/" 2>&1 \
  | grep -E '^\* +(subject|issuer|expire date):'
if curl -s -o /dev/null --max-time 10 --resolve "$name:443:127.0.0.1" "https://$name/"; then
  echo "certificate trusted: yes"
else
  echo "certificate trusted: no (still the placeholder, or the order failed)"
fi
systemctl show -p ActiveState -p Result "acme-order-renew-$name.service"
journalctl -u "acme-order-renew-$name" --no-pager -o cat -n 3

section "backups"
systemctl list-timers --no-pager sqlite-backup.timer | head -2
journalctl -u sqlite-backup --no-pager -o cat -n 4
sqlite-backup list 2>&1 | head -3
