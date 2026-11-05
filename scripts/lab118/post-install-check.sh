#!/usr/bin/env bash
# Read-only health report for lab118-services. Prints no secret values.
#
#   ssh lab118-services 'sudo bash -s' < scripts/lab118/post-install-check.sh
set -u

section() { printf '\n== %s\n' "$1"; }

section "system"
hostname
nixos-version
uptime

section "failed units"
systemctl --failed --no-legend --plain || true

section "services"
for unit in doppler-secrets doppler-secrets-refresh.timer nginx postgresql alerta alerta-bootstrap \
  alerta-apprise-forwarder ntfy-sh docker docker-apprise docker-node-red docker-uptime-kuma newt; do
  printf '%-32s %s\n' "$unit" "$(systemctl is-active "$unit")"
done

section "doppler-secrets (this boot)"
journalctl -u doppler-secrets -b --no-pager -o cat | tail -5
ls -l /var/lib/doppler-secrets/cache.json.age 2>&1
printf 'last refresh: result=%s exit=%s at %s\n' \
  "$(systemctl show -p Result --value doppler-secrets-refresh.service)" \
  "$(systemctl show -p ExecMainStatus --value doppler-secrets-refresh.service)" \
  "$(systemctl show -p ExecMainExitTimestamp --value doppler-secrets-refresh.service)"
journalctl -u doppler-secrets-refresh -b --no-pager -o cat | grep 'doppler-secrets:' | tail -3
find /run/doppler-secrets -type f ! -path '*/.work*' -printf '%m %u:%g %p\n' | sort

section "network"
ip -br addr
ip route
ip -6 route show default
resolvectl dns 2>/dev/null

section "listening sockets"
ss -Hltnup | awk '{ match($0, /users:\(\("[^"]+"/); print $1, $5, substr($0, RSTART + 9, RLENGTH - 10) }' | sort -u

section "containers"
docker ps --format '{{.Names}} | {{.Status}} | {{.Ports}}'

section "local health"
printf 'forwarder /healthz: %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9088/healthz)"
printf 'alerta healthcheck: %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:5000/management/healthcheck)"
printf 'ntfy /v1/health:    %s\n' "$(curl -s http://127.0.0.1:8080/v1/health)"
printf 'kuma UI:            %s\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3001/)"
printf 'node-red /intake/:  %s (via nginx :1880; 404 = no flows yet)\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1880/intake/)"
printf 'node-red editor on :1880: %s (expect 403)\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1880/)"
printf 'kuma status on :3002: %s (expect 403 from here; only the lab LAN may read it)\n' "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3002/api/status-page/lab)"

section "tls certificates"
for host in ntfy.lab118.xyz intake.lab118.xyz; do
  printf '%-26s %s\n' "$host" "$(systemctl is-active "acme-order-renew-${host}.service" 2>/dev/null) / $(systemctl show -p Result --value "acme-order-renew-${host}.service")"
done

section "newt"
journalctl -u newt -b --no-pager -o cat | tail -5
