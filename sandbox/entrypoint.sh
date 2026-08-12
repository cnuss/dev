#!/bin/sh
# Pin the resolver and install the sandbox CA, then hand off.
#
# The *_CA_BUNDLE environment variables in docker-compose.yml already cover
# most tools; the trust store install exists for the ones that read only the
# system store (openssl s_client, some Go and Rust binaries, apt).
set -eu

CERT=${SANDBOX_CA_CERT:-/certs/ca-cert.pem}
RESOLVER=${SANDBOX_RESOLVER:-}

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

# depends_on: service_healthy already orders this after the proxy, but a
# `docker compose up dev` with no deps, or a restart mid-CA-generation, can
# still land here early.
waited=0
while [ ! -s "$CERT" ]; do
    if [ "$waited" -ge 30 ]; then
        echo "sandbox: $CERT never appeared; continuing without the CA installed" >&2
        break
    fi
    [ "$waited" -eq 0 ] && echo "sandbox: waiting for $CERT ..."
    sleep 1
    waited=$((waited + 1))
done

if [ -s "$CERT" ]; then
    if command -v update-ca-certificates >/dev/null 2>&1; then
        mkdir -p /usr/local/share/ca-certificates
        cp "$CERT" /usr/local/share/ca-certificates/sandbox-egress-proxy.crt
        update-ca-certificates >/dev/null 2>&1 \
            && echo "sandbox: CA installed into the system trust store" \
            || echo "sandbox: update-ca-certificates failed; env CA vars still apply" >&2
    else
        echo "sandbox: no update-ca-certificates; relying on the *_CA_BUNDLE env vars" >&2
    fi
fi

exec "$@"
