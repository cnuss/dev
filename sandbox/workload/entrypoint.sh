#!/bin/sh
# Install the sandbox CA into the system trust store, then hand off.
#
# The *_CA_BUNDLE environment variables in docker-compose.yml already cover
# most tools; this exists for the ones that read only the system store
# (openssl s_client, some Go and Rust binaries, apt).
set -eu

CERT=${SANDBOX_CA_CERT:-/certs/ca-cert.pem}

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
