#!/bin/sh
# Pin the resolver and the default route, then hand off.
#
# The sandbox CA is baked into the image's trust store at build time (see the
# combined stage in ../Dockerfile), so there is nothing to install or wait for
# here — this script is now purely about networking.
set -eu

RESOLVER=${SANDBOX_RESOLVER:-}
GATEWAY=${SANDBOX_GATEWAY:-}

# Route everything at the proxy so it can intercept transparently.
#
# Docker installs its own default route via the bridge gateway; it must be
# *replaced*, not left alone, or traffic bypasses the proxy and dies at the
# host with no NAT (the sandbox network is created with
# enable_ip_masquerade=false). Pointing it at the proxy is what lets a client
# that ignores HTTPS_PROXY — Node's built-in fetch, a hand-rolled Go dialer —
# get captured instead of hanging, which is how the hosted environment behaves.
#
# `route replace` rather than `add`: idempotent across restarts, and correct
# whether or not Docker got there first.
if [ -n "$GATEWAY" ] && command -v ip >/dev/null 2>&1; then
    if ip route replace default via "$GATEWAY" 2>/dev/null; then
        echo "sandbox: default route via $GATEWAY (transparent capture)"
    else
        echo "sandbox: could not set a default route via $GATEWAY; only" >&2
        echo "         proxy-aware clients will reach the network" >&2
    fi
fi

# Point name resolution at the proxy's allowlist-filtering resolver.
#
# Docker writes its embedded resolver (127.0.0.11) into resolv.conf and
# forwards misses to the daemon's own nameservers — which keeps working on an
# `internal` network and is a DNS-exfiltration path out of the sandbox.
# Overwriting the file removes that entirely: the only resolver left is one
# with no route off the sandbox network. `proxy` still resolves because
# compose puts it in /etc/hosts, which nsswitch consults first.
#
# resolv.conf is a bind mount, so truncate in place — it cannot be replaced.
if [ -n "$RESOLVER" ]; then
    if printf 'nameserver %s\noptions timeout:2 attempts:2\n' "$RESOLVER" >/etc/resolv.conf 2>/dev/null; then
        echo "sandbox: resolver pinned to $RESOLVER"
    else
        echo "sandbox: could not rewrite /etc/resolv.conf; DNS is NOT confined" >&2
    fi
fi

exec "$@"
