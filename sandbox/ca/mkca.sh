#!/bin/sh
# Mint the sandbox egress CA into /certs, in the layout mitmproxy expects.
#
# Outputs:
#   /certs/mitmproxy-ca.pem      key + cert, read by mitmproxy (private)
#   /certs/mitmproxy-ca-cert.pem cert only, mitmproxy's own conventional name
#   /certs/ca-cert.pem           cert only, installed into workload trust stores
#   /certs/ca-bundle.crt         public roots + this CA, for *_CA_BUNDLE vars
#
# Idempotent: an existing CA is reused so restarting the stack does not
# invalidate trust stores that already have the old cert installed.
set -eu

CERTS=/certs
CA_CN=${CA_CN:-dev-sandbox egress proxy CA}
CA_DAYS=${CA_DAYS:-3650}
PROXY_UID=${PROXY_UID:-1000}

if [ -s "$CERTS/mitmproxy-ca.pem" ] && [ -s "$CERTS/ca-bundle.crt" ]; then
    echo "ca: reusing existing CA in $CERTS"
    echo "ca: subject $(openssl x509 -in "$CERTS/ca-cert.pem" -noout -subject 2>/dev/null || echo unknown)"
else
    echo "ca: generating a new CA (CN=$CA_CN, ${CA_DAYS}d)"
    openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
        -days "$CA_DAYS" \
        -keyout "$CERTS/ca-key.pem" \
        -out "$CERTS/ca-cert.pem" \
        -subj "/CN=$CA_CN" \
        -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
        -addext "keyUsage=critical,keyCertSign,cRLSign"

    cat "$CERTS/ca-key.pem" "$CERTS/ca-cert.pem" >"$CERTS/mitmproxy-ca.pem"
    cp "$CERTS/ca-cert.pem" "$CERTS/mitmproxy-ca-cert.pem"

    # The bundle keeps the public roots so that no_proxy destinations — which
    # never see the interception CA — still verify against a real chain.
    cat /etc/ssl/certs/ca-certificates.crt "$CERTS/ca-cert.pem" >"$CERTS/ca-bundle.crt"
fi

# The private key is only for the proxy; everything else is world-readable so
# any uid in the workload container can build a trust store from it.
# The directory itself must be writable by the proxy too — mitmproxy drops a
# mitmproxy-dhparam.pem into its confdir on startup.
chown "$PROXY_UID" "$CERTS"
chmod 0755 "$CERTS"
chown "$PROXY_UID" "$CERTS/mitmproxy-ca.pem" "$CERTS/ca-key.pem"
chmod 0600 "$CERTS/mitmproxy-ca.pem" "$CERTS/ca-key.pem"
chmod 0644 "$CERTS/ca-cert.pem" "$CERTS/mitmproxy-ca-cert.pem" "$CERTS/ca-bundle.crt"

echo "ca: ready"
openssl x509 -in "$CERTS/ca-cert.pem" -noout -subject -dates -fingerprint -sha256
