"""Healthcheck: the proxy is up only once both the CONNECT port and the status
endpoint are accepting connections, which also proves the addon loaded."""

import os
import socket
import sys

for port in (
    int(os.environ.get("SANDBOX_LISTEN_PORT", "8080")),
    int(os.environ.get("SANDBOX_STATUS_PORT", "8081")),
):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=2).close()
    except OSError as exc:
        print(f"port {port}: {exc}", file=sys.stderr)
        sys.exit(1)
