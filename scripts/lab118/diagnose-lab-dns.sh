#!/usr/bin/env bash
# Read-only: query lab DNS through the tunnel over UDP and TCP, and show which
# address UDP replies come from. Run on lab118-services:
#
#   ssh lab118-services 'sudo bash -s' < scripts/lab118/diagnose-lab-dns.sh
set -u

python3 - <<'PY'
import random
import socket
import struct

NAME = "pangolin-newt.host.internal"


def query():
    header = struct.pack(">HHHHHH", random.randint(0, 0xFFFF), 0x0100, 1, 0, 0, 0)
    qname = b"".join(bytes([len(label)]) + label.encode() for label in NAME.split(".")) + b"\0"
    return header + qname + struct.pack(">HH", 1, 1)


def summary(message):
    return f"rcode={message[3] & 0x0F} answers={struct.unpack('>H', message[6:8])[0]}"


for server in ("10.0.0.1", "10.118.0.2"):
    # Unconnected UDP socket: accepts a reply from any source address, so a
    # reply from the wrong address is visible instead of silently dropped.
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.settimeout(3)
    udp.sendto(query(), (server, 53))
    try:
        data, source = udp.recvfrom(4096)
        note = "" if source[0] == server else "  <-- WRONG SOURCE (clients drop this)"
        print(f"UDP {server}: reply from {source[0]} {summary(data)}{note}")
    except socket.timeout:
        print(f"UDP {server}: no reply within 3s from any address")
    finally:
        udp.close()

    try:
        packet = query()
        with socket.create_connection((server, 53), timeout=3) as tcp:
            tcp.sendall(struct.pack(">H", len(packet)) + packet)
            data = tcp.recv(4096)
        print(f"TCP {server}: reply {summary(data[2:])}")
    except OSError as exc:
        print(f"TCP {server}: failed ({exc.__class__.__name__})")
PY
