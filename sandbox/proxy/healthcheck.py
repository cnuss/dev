"""Healthcheck: the proxy is up once the CONNECT port, the status endpoint,
and the filtering resolver all answer.

The DNS probe asks for a name that cannot be on the allowlist, so a healthy
answer is NXDOMAIN produced locally by the addon. That proves the resolver is
listening *and* that the policy hook is loaded, without generating a single
upstream query.
"""

import os
import random
import socket
import struct
import sys

PROBE = "healthcheck.sandbox.invalid"
NXDOMAIN = 3


def check_tcp(port: int) -> None:
    socket.create_connection(("127.0.0.1", port), timeout=2).close()


def check_dns(port: int) -> None:
    tid = random.randint(0, 0xFFFF)
    query = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    for label in PROBE.split("."):
        query += bytes([len(label)]) + label.encode()
    query += b"\x00" + struct.pack(">HH", 1, 1)  # QTYPE=A, QCLASS=IN

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2)
    try:
        sock.sendto(query, ("127.0.0.1", port))
        data, _ = sock.recvfrom(512)
    finally:
        sock.close()

    if len(data) < 12 or data[:2] != query[:2]:
        raise OSError("malformed or mismatched DNS response")
    rcode = struct.unpack(">H", data[2:4])[0] & 0x000F
    if rcode != NXDOMAIN:
        raise OSError(f"expected NXDOMAIN for {PROBE}, got rcode {rcode}")


checks = (
    ("proxy", check_tcp, int(os.environ.get("SANDBOX_LISTEN_PORT", "8080"))),
    ("status", check_tcp, int(os.environ.get("SANDBOX_STATUS_PORT", "8081"))),
    ("transparent", check_tcp, int(os.environ.get("SANDBOX_TRANSPARENT_PORT", "8082"))),
    ("dns", check_dns, int(os.environ.get("SANDBOX_DNS_PORT", "53"))),
)

for name, check, port in checks:
    try:
        check(port)
    except OSError as exc:
        print(f"{name} (port {port}): {exc}", file=sys.stderr)
        sys.exit(1)
