#!/usr/bin/env bash
# Read-only health report for the dashboard VM. Prints no secret values.
#
#   ssh dashboard 'sudo bash -s' < scripts/dashboard/post-install-check.sh
#
# Expect beszel-agent inactive until the hub public key is set.
set -u

section() { printf '\n== %s\n' "$1"; }
code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

section "system"
hostname
nixos-version
uptime

section "failed units"
systemctl --failed --no-legend --no-pager || true

section "services"
for unit in docker docker-homarr beszel-hub beszel-agent nginx \
  sqlite-backup.timer homarr-health-watch.timer mnt-dashboard\\x2dbackups.automount; do
  printf '%-36s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null)"
done

section "homarr"
docker inspect --format 'image {{.Config.Image}}
health {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}, restarts {{.RestartCount}}' homarr 2>&1
printf 'key in docker inspect: %s (expect 0)\n' \
  "$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' homarr | grep -c '^SECRET_ENCRYPTION_KEY=')"
# docker top refuses a ps format without a PID column.
uids="$(docker top homarr -o pid,uid | awk 'NR > 1 { print $2 }')"
printf 'processes as uid 7575: %s of %s\n' "$(grep -cx 7575 <<<"$uids")" "$(grep -c . <<<"$uids")"
stat -c '%U:%G %a %n' /var/lib/homarr /var/lib/homarr/db /var/lib/homarr/db/db.sqlite /var/lib/homarr/.secret-encryption-key.sha256 2>&1
printf '/api/health/live on loopback: %s\n' "$(code http://127.0.0.1:7575/api/health/live)"

section "beszel hub"
printf '/api/health on loopback: %s\n' "$(code http://127.0.0.1:8090/api/health)"
stat -c '%U:%G %a %F %n' /var/lib/beszel-hub /var/lib/beszel-hub/beszel_data /var/lib/beszel-hub/beszel_data/data.db /var/lib/beszel-hub/beszel_data/id_ed25519 2>&1
printf 'hub public key: %s\n' "$(ssh-keygen -y -f /var/lib/beszel-hub/beszel_data/id_ed25519 2>/dev/null | cut -d' ' -f1-2)"
journalctl -u beszel-agent -b --no-pager -o cat | tail -3

section "listening sockets (expect 22, 80, 443 public, plus rpcbind and LLMNR that the firewall drops; 7575, 8090 on 127.0.0.1)"
ss -tlnp | awk 'NR == 1 || /LISTEN/'

section "nginx from this host (MCP routes 404; 127.0.0.1 isn't on the allow-lists, so the rest is 403)"
for path in /api/mcp /API/MCP /api/mcp/oauth/token /.well-known/oauth-authorization-server /en/auth/mcp /; do
  printf '%-44s %s\n' "dashboard.servicestack.xyz$path" \
    "$(code --resolve dashboard.servicestack.xyz:443:127.0.0.1 "https://dashboard.servicestack.xyz$path")"
done
printf '%-44s %s (expect 000: no certificate for unknown names)\n' "https://127.0.0.1/" "$(code https://127.0.0.1/)"

# The host has no openssl; curl's handshake log shows the served certificate.
# Until the first order succeeds, nginx serves a self-signed placeholder.
section "tls certificate"
curl -skv -o /dev/null --max-time 10 --resolve dashboard.servicestack.xyz:443:127.0.0.1 \
  https://dashboard.servicestack.xyz/ 2>&1 | grep -E '^\* +(subject|issuer|expire date):'
if curl -s -o /dev/null --max-time 10 --resolve dashboard.servicestack.xyz:443:127.0.0.1 \
    https://dashboard.servicestack.xyz/; then
  echo "certificate trusted: yes"
else
  echo "certificate trusted: no (still the placeholder, or the order failed)"
fi
systemctl show -p ActiveState -p Result acme-order-renew-dashboard.servicestack.xyz.service
journalctl -u acme-order-renew-dashboard.servicestack.xyz --no-pager -o cat -n 3
systemctl list-timers --no-pager 'acme-*' 2>/dev/null | head -4

section "backups"
systemctl list-timers --no-pager sqlite-backup.timer | head -2
journalctl -u sqlite-backup --no-pager -o cat -n 4
sqlite-backup list 2>&1 | head -3
