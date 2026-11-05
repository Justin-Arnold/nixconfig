#!/usr/bin/env bash
# Read-only inspection of a freshly bought cloud server (stock image), run
# before installing NixOS. Prints what hosts/<host>/facts.nix needs: firmware
# mode, disk path, MAC, IPv4/IPv6 addresses and gateways. Changes nothing.
#
#   ssh -i ~/.ssh/homelab_provision -o IdentitiesOnly=yes root@<ip> 'bash -s' \
#     < scripts/provisioning/inspect-cloud-host.sh
set -u

section() { printf '\n== %s\n' "$1"; }

section "os"
# shellcheck source=/dev/null
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"
uname -r
systemd-detect-virt 2>/dev/null || true

section "firmware"
if [ -d /sys/firmware/efi ]; then echo "uefi"; else echo "bios"; fi

section "cpu / memory"
nproc
free -m | awk 'NR<=2'

section "disks"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL,TRAN,ROTA
echo
find /dev/disk/by-id/ -maxdepth 1 -type l ! -name '*-part*' -printf '%f -> %l\n' 2>/dev/null | sort
echo
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS

section "interfaces"
ip -br link
ip -br addr

section "ipv4"
ip -4 -o addr show scope global
ip -4 route

section "ipv6"
ip -6 -o addr show scope global
ip -6 route show default
ip -6 route | grep -v '^fe80' || true

section "dns"
resolvectl status 2>/dev/null | grep -E 'DNS Servers|Current DNS' || cat /etc/resolv.conf

section "network config files (provider image)"
for f in /etc/netplan/*.yaml /etc/network/interfaces /etc/cloud/cloud.cfg.d/*network*; do
  [ -f "$f" ] || continue
  echo "--- $f"
  # Network config only; never contains credentials on stock images.
  grep -vE '^\s*#|password|passwd' "$f"
done

section "kexec readiness (nixos-anywhere)"
cat /proc/sys/kernel/kexec_load_disabled 2>/dev/null || echo "kexec_load_disabled: n/a"
df -h /root /tmp | awk 'NR==1 || /\//'
