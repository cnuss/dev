"""Allowlist-enforcing egress policy for the compose sandbox.

Loaded into mitmdump as an addon. One allowlist governs two tiers:

Traffic (regular proxy mode)
  * CONNECT to a host that is not in the allowlist -> 403, connection aborted
    before mitmproxy dials upstream.
  * CONNECT to a port outside SANDBOX_ALLOWED_PORTS -> 403.
  * A plain-HTTP, absolute-form proxy request (i.e. a client configured with
    HTTP_PROXY rather than HTTPS_PROXY) -> 405, unless
    SANDBOX_ALLOW_PLAIN_HTTP=1.

Names (DNS mode)
  * The sandbox has no route to any resolver, so this is the only one it can
    reach. A query for a name that is not in the allowlist is answered
    NXDOMAIN locally and never leaves the box.

Filtering DNS is what closes the exfiltration channel: a query for
`<secrets>.attacker.example` cannot be smuggled out as a lookup, because a
name has to be on the allowlist before the resolver will forward it at all.
NXDOMAIN rather than REFUSED so glibc fails fast and definitively ("Name or
service not known") instead of retrying and reporting a temporary failure.

The allowlist is re-read whenever the file's mtime changes, so editing
allowlist.txt takes effect without a restart.

A read-only status endpoint mirroring the hosted proxy's /__agentproxy/status
is served on SANDBOX_STATUS_PORT; it reports the active rules and the most
recent denials, which is the fast way to find out why something failed (the
403 body never reaches curl on a failed CONNECT, and a resolver reports only
"not found").
"""

from __future__ import annotations

import collections
import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from mitmproxy import dns
from mitmproxy import http
from mitmproxy.net.dns import response_codes

logger = logging.getLogger(__name__)

ALLOWLIST_PATH = os.environ.get("SANDBOX_ALLOWLIST", "/etc/sandbox/allowlist.txt")
STATUS_PORT = int(os.environ.get("SANDBOX_STATUS_PORT", "8081"))
ALLOW_PLAIN_HTTP = os.environ.get("SANDBOX_ALLOW_PLAIN_HTTP", "0") == "1"
ALLOWED_PORTS = frozenset(
    int(p) for p in os.environ.get("SANDBOX_ALLOWED_PORTS", "443").replace(",", " ").split()
)

# The container healthcheck resolves this every few seconds to prove the DNS
# listener and this addon are both live. It is refused like anything else, but
# kept out of the counters so it cannot crowd real denials out of the ring
# buffer — 50 entries would otherwise be four minutes of healthchecks.
HEALTHCHECK_NAME = "healthcheck.sandbox.invalid"


def parse_rules(path: str) -> list[str]:
    """Read allowlist.txt into normalised rules.

    `*`             any host at all — open egress, the hosted default
    `example.com`   exact host only
    `.example.com`  the domain and any subdomain of it
    `*.example.com` same as the above (accepted for familiarity)
    """
    rules: list[str] = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip().lower().rstrip(".")
            if not line:
                continue
            if line != "*" and line.startswith("*."):
                line = line[1:]
            rules.append(line)
    return rules


def match_rule(host: str, rules: list[str]) -> str | None:
    host = host.lower().rstrip(".")
    for rule in rules:
        if rule == "*":
            return rule
        if rule.startswith("."):
            if host == rule[1:] or host.endswith(rule):
                return rule
        elif host == rule:
            return rule
    return None


def is_transparent(flow: object) -> bool:
    """True when the flow was captured by the redirect rather than handed to
    us by a proxy-aware client. Transparent flows have no CONNECT and carry
    plain HTTP on :80 legitimately, so two of the regular-mode rules do not
    apply to them."""
    try:
        return type(flow.client_conn.proxy_mode).__name__ == "TransparentMode"
    except AttributeError:
        return False


class SandboxEgress:
    def __init__(self) -> None:
        self.rules: list[str] = []
        self.mtime: float = -1.0
        self.lock = threading.Lock()
        self.denials: collections.deque[dict] = collections.deque(maxlen=50)
        self.allowed_count = 0
        self.denied_count = 0
        self.dns_allowed_count = 0
        self.dns_denied_count = 0
        self.status_thread: threading.Thread | None = None

    # -- lifecycle ---------------------------------------------------------

    def running(self) -> None:
        self.refresh(force=True)
        if self.status_thread is None:
            self.status_thread = threading.Thread(
                target=self._serve_status, name="sandbox-status", daemon=True
            )
            self.status_thread.start()

    def refresh(self, force: bool = False) -> None:
        try:
            mtime = os.stat(ALLOWLIST_PATH).st_mtime
        except OSError as exc:
            if force:
                logger.warning(f"sandbox: cannot read {ALLOWLIST_PATH} ({exc}); denying everything")
                with self.lock:
                    self.rules = []
            return
        if not force and mtime == self.mtime:
            return
        try:
            rules = parse_rules(ALLOWLIST_PATH)
        except OSError as exc:
            logger.warning(f"sandbox: cannot read {ALLOWLIST_PATH} ({exc}); keeping previous rules")
            return
        with self.lock:
            self.rules = rules
            self.mtime = mtime
        logger.info(f"sandbox: loaded {len(rules)} allowlist rule(s) from {ALLOWLIST_PATH}")

    # -- policy ------------------------------------------------------------

    def http_connect(self, flow: http.HTTPFlow) -> None:
        self.refresh()
        host, port = flow.request.host, flow.request.port

        if port not in ALLOWED_PORTS:
            self._deny(flow, host, port, "port-not-allowed", 403)
            return

        with self.lock:
            rules = self.rules
        if match_rule(host, rules) is None:
            self._deny(flow, host, port, "not-in-allowlist", 403)
            return

        with self.lock:
            self.allowed_count += 1

    def request(self, flow: http.HTTPFlow) -> None:
        # Runs for plain-HTTP proxy requests and, after a permitted CONNECT,
        # for each intercepted request inside the tunnel. Re-checking the host
        # here closes the gap between the CONNECT target and the Host header.
        if flow.response is not None:
            return

        # 405 is a statement about proxy *configuration* — a client that set
        # HTTP_PROXY and sent an absolute-form request. A transparently
        # captured :80 request is not that, and must be allowed through.
        if (
            flow.request.scheme == "http"
            and not ALLOW_PLAIN_HTTP
            and not is_transparent(flow)
        ):
            self._deny(
                flow,
                flow.request.pretty_host,
                flow.request.port,
                "plain-http-not-supported",
                405,
            )
            return

        self.refresh()
        host = flow.request.pretty_host
        with self.lock:
            rules = self.rules
        if match_rule(host, rules) is None:
            self._deny(flow, host, flow.request.port, "not-in-allowlist", 403)

    # -- DNS ---------------------------------------------------------------

    def dns_request(self, flow: dns.DNSFlow) -> None:
        # The sandbox network has no route to any other resolver, so every
        # lookup the workload makes arrives here. Anything not on the allowlist
        # is answered locally and never reaches an upstream server.
        if flow.response is not None:
            return

        self.refresh()
        with self.lock:
            rules = self.rules

        for question in flow.request.questions:
            name = question.name
            # Answered locally whatever the policy says, so the probe stays
            # hermetic: no upstream query, and a broken forwarder cannot make
            # the container look unhealthy.
            if name.lower().rstrip(".") == HEALTHCHECK_NAME:
                flow.response = flow.request.fail(response_codes.NXDOMAIN)
                return
            if match_rule(name, rules) is None:
                self._record(name, 53, "dns-not-in-allowlist", "NXDOMAIN")
                with self.lock:
                    self.dns_denied_count += 1
                logger.warning(f"sandbox: DENY dns {name} -> NXDOMAIN")
                flow.response = flow.request.fail(response_codes.NXDOMAIN)
                return

        with self.lock:
            self.dns_allowed_count += 1

    # -- shared ------------------------------------------------------------

    def _record(self, host: str, port: int, reason: str, status: object) -> None:
        with self.lock:
            self.denied_count += 1
            self.denials.appendleft(
                {
                    "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "host": host,
                    "port": port,
                    "reason": reason,
                    "status": status,
                }
            )

    def _deny(self, flow: http.HTTPFlow, host: str, port: int, reason: str, status: int) -> None:
        self._record(host, port, reason, status)
        logger.warning(f"sandbox: DENY {host}:{port} ({reason}) -> {status}")
        flow.response = http.Response.make(
            status,
            (
                f"sandbox egress proxy: {reason}\n"
                f"host: {host}:{port}\n"
                f"Add it to allowlist.txt, or see http://proxy:{STATUS_PORT}/status\n"
            ).encode(),
            {"Content-Type": "text/plain; charset=utf-8", "X-Sandbox-Deny": reason},
        )

    # -- status endpoint ---------------------------------------------------

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "enabled": True,
                "listenPort": int(os.environ.get("SANDBOX_LISTEN_PORT", "8080")),
                "dnsPort": int(os.environ.get("SANDBOX_DNS_PORT", "53")),
                "statusPort": STATUS_PORT,
                "allowlistPath": ALLOWLIST_PATH,
                "allowlist": list(self.rules),
                "allowedPorts": sorted(ALLOWED_PORTS),
                "allowPlainHttp": ALLOW_PLAIN_HTTP,
                "caCertPath": "/usr/local/share/ca-certificates/dev.crt",
                "caBundlePath": "/etc/ssl/certs/ca-certificates.crt",
                "allowedRequests": self.allowed_count,
                "deniedRequests": self.denied_count,
                "dnsAllowedQueries": self.dns_allowed_count,
                "dnsDeniedQueries": self.dns_denied_count,
                "recentDenials": list(self.denials),
            }

    def _serve_status(self) -> None:
        addon = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self) -> None:  # noqa: N802 - stdlib naming
                if self.path.rstrip("/") not in ("", "/status", "/__sandbox/status"):
                    self.send_error(404, "try /status")
                    return
                body = json.dumps(addon.snapshot(), indent=2).encode() + b"\n"
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args) -> None:
                pass

        try:
            ThreadingHTTPServer(("0.0.0.0", STATUS_PORT), Handler).serve_forever()
        except OSError as exc:
            logger.warning(f"sandbox: status endpoint unavailable on :{STATUS_PORT} ({exc})")


addons = [SandboxEgress()]
