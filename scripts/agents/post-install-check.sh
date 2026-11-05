#!/usr/bin/env bash
# Read-only health report for the agents VM. Prints no secret values.
#
#   ssh agents 'sudo bash -s' < scripts/agents/post-install-check.sh
set -u

section() { printf '\n== %s\n' "$1"; }
code() { curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
name=paperclip.servicestack.xyz

section "system"
hostname
nixos-version
uptime

section "failed units"
systemctl --failed --no-legend --no-pager || true

section "services"
for unit in postgresql paperclip-db-password podman-paperclip hermes-coordinator hermes-engineer hermes-researcher hermes-reviewer hermes-infra beszel-agent nginx \
  sqlite-backup.timer paperclip-health-watch.timer mnt-agents\\x2dbackups.automount; do
  printf '%-36s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null)"
done
printf 'docker installed: %s (expect no)\n' "$(command -v docker >/dev/null && echo yes || echo no)"

section "paperclip"
podman inspect --format 'image {{.ImageName}}
running {{.State.Running}}, restarts {{.RestartCount}}, user {{.Config.User}}, network {{.HostConfig.NetworkMode}}' paperclip 2>&1
for var in BETTER_AUTH_SECRET PAPERCLIP_AGENT_JWT_SECRET DATABASE_URL; do
  printf '%s in podman inspect: %s (expect 1, from the root-only env file)\n' "$var" \
    "$(podman inspect --format '{{range .Config.Env}}{{println .}}{{end}}' paperclip | grep -c "^$var=")"
done
# podman top's huser prints "?" for a process it can't match on the host (the
# esbuild Paperclip starts on demand), so read users from the host's process
# table, by the container's cgroup.
scope="libpod-$(podman inspect --format '{{.Id}}' paperclip).scope"
procs=$(ps -e -ww -o user:32=,pid=,etime=,comm=,cgroup= | awk -v s="$scope" 'index($0, s) {print $1, $2, $3, $4}')
others=$(awk '$1 != "paperclip"' <<<"$procs")
printf 'processes in the container: %s, not running as paperclip: %s (expect 0)\n' \
  "$(grep -c . <<<"$procs")" "$(grep -c . <<<"$others")"
[[ -n $others ]] && printf '  %s\n' "${others//$'\n'/$'\n  '}"
stat -c '%U:%G %a %n' /var/lib/paperclip /var/lib/paperclip/.master-key.sha256 2>&1
stat -L -c '%U:%G %a master key (SOPS)' /run/secrets/paperclip/master-key 2>&1
printf '/api/health on loopback: %s\n' "$(code http://127.0.0.1:3100/api/health)"
curl -s --max-time 10 http://127.0.0.1:3100/api/health \
  | jq -c '{status} + with_entries(select(.key | test("deployment|auth|bind"; "i")))' 2>/dev/null
# Paperclip logs JSON with numeric levels (40 warn, 50 error); matching the
# text would also catch migration names like 0103_agent_error_reason.
echo "warnings and errors this boot (last 5):"
journalctl -u podman-paperclip -b --no-pager -o cat \
  | jq -Rr '(try fromjson catch null) as $j
      | if ($j | type) == "object" then select(($j.level // 0) >= 40) | "\($j.level) \($j.msg // "")"
        else select(test("error|warn"; "i")) end' \
  | cut -c1-200 | tail -5

# Ports from roles.hermesAgents; /health needs no key. Hermes logs to files
# under its home, not the journal, and the gateway stays up when only its API
# server fails to start.
section "hermes agents"
for agent in coordinator:8642 engineer:8643 researcher:8644 reviewer:8645 infra:8646; do
  n=${agent%%:*}
  port=${agent##*:}
  home=/var/lib/hermes-$n/.hermes
  health=$(code "http://127.0.0.1:$port/health")
  # The API server binds a few seconds after the unit goes active.
  up=$(ps -o etime= -p "$(systemctl show -p MainPID --value "hermes-$n")" 2>/dev/null | tr -d ' ')
  printf '%-12s %-9s up %s, restarts %s, /health %s, Codex login: %s\n' "$n" "$(systemctl is-active "hermes-$n" 2>/dev/null)" \
    "${up:--}" "$(systemctl show -p NRestarts --value "hermes-$n")" "$health" \
    "$([[ -s $home/auth.json ]] && echo yes || echo no)"
  stat -c '  %U:%G %a %n' "$home/config.yaml" "$home/.env" "$home/SOUL.md" 2>&1
  if [[ $health != 200 ]]; then
    echo "  API server log:"
    grep -E 'API server|API_SERVER_KEY|Could not bind' "$home/logs/gateway.log" 2>&1 | tail -3 | cut -c1-200 | sed 's/^/    /'
    echo "  errors.log:"
    tail -n 5 "$home/logs/errors.log" 2>&1 | cut -c1-200 | sed 's/^/    /'
  fi
done
echo "expect root:hermes-<name> 640 on all three files, so the agent can read them but not change them"

# Run as an agent, so the LAN attempts are refused on this host and never
# reach their targets.
section "agent egress (expect Paperclip 200, OpenAI answering, the LAN 000 in 0s)"
nft list chain inet agent-egress output 2>&1 | grep -oE 'meta skuid .*|Error.*'
for target in http://127.0.0.1:3100/api/health https://api.openai.com/ http://10.0.0.1:3000/ http://10.0.0.20/; do
  printf '%-36s %s\n' "$target" \
    "$(runuser -u hermes-coordinator -- curl -s -o /dev/null -w '%{http_code} in %{time_total}s' --max-time 5 "$target")"
done
printf 'refused so far: %s\n' "$(nft list chain inet agent-egress refuse 2>&1 | grep -oE 'packets [0-9]+')"
# The uid comes last in the kernel's log line, so print only what matters.
echo "last refusals this boot (two are from this check):"
journalctl -k -b --no-pager -o short-iso -g 'agent-egress refused' | tail -5 \
  | sed -E 's/^([^ ]+) .* DST=([^ ]+) .*PROTO=([A-Z]+).* DPT=([0-9]+).* UID=([0-9]+).*/  \1 \3 \2:\4 uid \5/' | cut -c1-200

section "agent-watch (a pass every 5 minutes; the last should end in 'alert(s) held')"
printf 'Alerta over the lab tunnel: %s (expect 200; 000 means the tunnel or route is down)\n' \
  "$(code http://10.118.0.1:5000/management/healthcheck)"
if [[ $(systemctl show -p LoadState --value agent-watch.timer) == loaded ]]; then
  systemctl list-timers --no-pager agent-watch.timer | head -2
  printf 'last pass: %s\n' "$(systemctl show -p Result --value agent-watch)"
  journalctl -u agent-watch --no-pager -o cat -n 3 | cut -c1-200
else
  echo "off (agents.watch.enable)"
fi

section "postgresql"
sudo -u postgres psql -Atc "select 'server ' || current_setting('server_version')"
sudo -u postgres psql -Atc "select 'listen_addresses ' || current_setting('listen_addresses')"
sudo -u postgres psql -Atc "select 'paperclip owns ' || count(*) || ' tables' from pg_tables where tableowner = 'paperclip'" paperclip

section "listening sockets (expect 22, 80, 443 public, plus rpcbind and LLMNR that the firewall drops; 3100, 5432, 8642 to 8646 and one random port per agent on 127.0.0.1)"
ss -tlnp | awk 'NR == 1 || /LISTEN/'

section "nginx from this host (guarded routes 404; 127.0.0.1 isn't on the allow-lists, so the rest is 403)"
for path in /mcp /mcp/paperclip /MCP/paperclip /.well-known/oauth-authorization-server \
  /api/routine-triggers/public/x/fire /api/health /; do
  printf '%-58s %s\n' "$name$path" "$(code --resolve "$name:443:127.0.0.1" "https://$name$path")"
done
printf '%-58s %s (expect 000: no certificate for unknown names)\n' "https://127.0.0.1/" "$(code https://127.0.0.1/)"

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
