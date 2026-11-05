#!/usr/bin/env bash
# Read-only health report for workbench. Prints no secret values.
#
#   ssh workbench 'sudo bash -s' < scripts/workbench/post-install-check.sh
set -u

section() { printf '\n== %s\n' "$1"; }
agents=$(getent passwd | awk -F: '$1 ~ /^agent-/ {print $1}')

section "system"
hostname
nixos-version
uptime
df -h / | tail -1

section "failed units"
systemctl --failed --no-legend --no-pager || true

section "services"
# nix-daemon starts on demand, so its socket is what should be active.
for unit in sshd nftables beszel-agent nix-daemon.socket prune-worktrees.timer nix-gc.timer nix-optimise.timer; do
  printf '%-24s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null)"
done
printf 'docker installed: %s (expect no)\n' "$(command -v docker >/dev/null && echo yes || echo no)"

section "agent users (expect no wheel, no sudo, a 700 home, subuids, and keys limited to 10.0.0.152)"
for user in $agents; do
  home=$(getent passwd "$user" | cut -d: -f6)
  echo "$user: $(id "$user")"
  printf '  home %s, subuids %s\n' "$(stat -c '%U %a' "$home")" "$(grep -c "^$user:" /etc/subuid)"
  sudo -l -U "$user" 2>&1 | tail -1 | sed 's/^/  sudo: /'
  # The options before each key, not the key.
  sed -n 's/ssh-[a-z0-9]* .*//p' "/etc/ssh/authorized_keys.d/$user" 2>/dev/null | sed 's/^/  key options: /'
  [[ -s /etc/ssh/authorized_keys.d/$user ]] || echo "  no key yet"
done

section "sshd for an agent from the agents VM (expect every forwarding, tty and rc off)"
for user in $agents; do
  sshd -T -C "user=$user,host=agents,addr=10.0.0.152" 2>&1 \
    | grep -E '^(allowtcpforwarding|allowagentforwarding|allowstreamlocalforwarding|x11forwarding|permittunnel|permittty|permituserrc|allowusers) ' \
    | sed "s/^/  $user: /"
done

section "nix (expect agents not trusted, sandbox on)"
for setting in trusted-users sandbox; do
  printf '%s = %s\n' "$setting" "$(nix config show "$setting" 2>&1)"
done

section "agent egress (expect GitHub answering, the LAN 000 in 0s)"
nft list chain inet agent-egress output 2>&1 | grep -oE 'meta sk[ug]id .*|Error.*'
first=$(head -1 <<<"$agents")
if [[ -n $first ]]; then
  for target in https://github.com/ https://10.0.0.152/ http://10.0.0.1:3000/; do
    printf '%-28s %s\n' "$target" \
      "$(runuser -u "$first" -- curl -sk -o /dev/null -w '%{http_code} in %{time_total}s' --max-time 5 "$target")"
  done
fi
printf 'refused so far: %s\n' "$(nft list chain inet agent-egress refuse 2>&1 | grep -oE 'packets [0-9]+')"

section "github (expect the machine account, scopes 'repo' only)"
if [[ -e /run/secrets/github/token ]]; then
  stat -L -c 'token %U:%G %a' /run/secrets/github/token
  git config --system --get-regexp '^(user\.|credential\.)' | sed 's/^/  /'
  [[ -n $first ]] && runuser -u "$first" -- env HOME=/tmp gh auth status 2>&1 | grep -E 'Logged in|scopes' | sed 's/^/  /'
else
  echo "no token (workbench.github isn't set)"
fi

section "worktrees and containers"
for user in $agents; do
  home=$(getent passwd "$user" | cut -d: -f6)
  printf '%s: %s repos, %s worktrees, %s in its home\n' "$user" \
    "$(find "$home/repos" -mindepth 2 -maxdepth 2 -name '*.git' 2>/dev/null | wc -l)" \
    "$(find "$home/work" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l)" \
    "$(du -sh "$home" 2>/dev/null | cut -f1)"
done
journalctl -u prune-worktrees --no-pager -o cat -n 5

section "listening sockets (expect 22 public, LLMNR that the firewall drops, and resolved's 53 on loopback)"
ss -tlnp | awk 'NR == 1 || /LISTEN/'
