#!/usr/bin/env bash
# Read-only checks of the router <-> lab118-services WireGuard tunnel, run on
# lab118-services. Prints no secrets (wg hides the private key).
#
#   ssh lab118-services 'sudo bash -s' < scripts/lab118/check-lab-tunnel.sh
set -u

section() { printf '\n== %s\n' "$1"; }

section "wireguard"
wg show wg-lab
networkctl status wg-lab --no-pager 2>/dev/null | sed -n '1,12p'

section "routes via the tunnel (expect only 10.0.0.0/24 and the tunnel /30)"
ip route show dev wg-lab
printf 'default route: '
ip route show default

section "router tunnel IP 10.118.0.2"
ping -c 3 -W 2 10.118.0.2

section "LAN gateway 10.0.0.1 through the tunnel"
ping -c 3 -W 2 10.0.0.1

section "lab DNS through the tunnel (expect 10.0.0.72 via link wg-lab)"
resolvectl query pangolin-newt.host.internal

section "public DNS stays public (expect link ens18)"
resolvectl query example.com

section "from the Kuma container"
docker exec uptime-kuma ping -c 2 -W 2 10.0.0.1
printf 'container resolves pangolin-newt.host.internal: '
docker exec uptime-kuma getent hosts pangolin-newt.host.internal || echo "FAILED"

section "least privilege (expect 000 = blocked by the router)"
curl -sk -m 5 -o /dev/null -w 'router web UI from the cloud: %{http_code}\n' https://10.0.0.1/

section "Internet does not use the tunnel"
ip route get 1.1.1.1
curl -s -m 10 -o /dev/null -w 'https://ntfy.sh from the host: %{http_code}\n' https://ntfy.sh/

section "WAN reachability (needs the WAN ping rule; fails until then)"
ping -c 3 -W 2 45.43.99.13
