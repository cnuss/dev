#!/bin/sh
# Program the transparent-capture rules, then hand off to the mitmproxy image's
# own entrypoint (which gosu-drops privileges when argv[0] is a mitmproxy tool).
#
# This is what makes the sandbox behave like the hosted environment: outbound
# :80 and :443 are intercepted regardless of whether the client honours
# HTTPS_PROXY, and :53 is answered by the local resolver no matter which
# nameserver the client aimed at.
#
# Fail-closed by construction. FORWARD policy is DROP and no MASQUERADE rule is
# ever added, so the only thing a sandbox packet can do is get REDIRECTed to a
# listener in this container. If the redirect rules are wrong, traffic dies
# here — it does not leak out as NAT.
set -eu

SUBNET=${SANDBOX_SUBNET:-172.31.240.0/24}
TRANSPARENT_PORT=${SANDBOX_TRANSPARENT_PORT:-8082}
DNS_PORT=${SANDBOX_DNS_PORT:-53}
CAPTURE_PORTS=${SANDBOX_CAPTURE_PORTS:-80,443}
CONFDIR=${SANDBOX_CONFDIR:-/var/lib/mitmproxy}
CA_SRC=${SANDBOX_CA_PEM:-/etc/ssl/private/dev.pem}

# Seed mitmproxy's confdir from the CA baked into the image at build time.
#
# Copied rather than symlinked, and into a dedicated directory rather than
# /etc/ssl/private: mitmproxy writes mitmproxy-dhparam.pem alongside its CA on
# startup, so the confdir has to be writable by the user the base image's
# docker-entrypoint.sh gosu-drops to. /etc/ssl/private stays 0700 root.
#
# Without this, mitmproxy would silently generate its own throwaway CA and
# nothing in the workload image would trust it.
if [ -s "$CA_SRC" ]; then
    PROXY_USER=${SANDBOX_PROXY_USER:-mitmproxy}
    id "$PROXY_USER" >/dev/null 2>&1 || PROXY_USER=${SANDBOX_PROXY_UID:-1000}

    mkdir -p "$CONFDIR"
    cp "$CA_SRC" "$CONFDIR/mitmproxy-ca.pem"
    chown -R "$PROXY_USER" "$CONFDIR"
    chmod 0700 "$CONFDIR"
    chmod 0600 "$CONFDIR/mitmproxy-ca.pem"
    echo "proxy: CA seeded into $CONFDIR from $CA_SRC"
else
    echo "proxy: $CA_SRC missing; mitmproxy will mint a CA the workload does not trust" >&2
fi

if [ "${SANDBOX_TRANSPARENT:-1}" = "1" ]; then
    if ! command -v iptables >/dev/null 2>&1; then
        echo "proxy: iptables missing; transparent capture disabled" >&2
    elif ! iptables -w -t nat -L PREROUTING >/dev/null 2>&1; then
        echo "proxy: no NET_ADMIN; transparent capture disabled (explicit proxy still works)" >&2
    else
        # Drop first, so there is never a window where forwarding is on and
        # unfiltered.
        iptables -w -P FORWARD DROP

        iptables -w -t nat -A PREROUTING -s "$SUBNET" -p tcp \
            -m multiport --dports "$CAPTURE_PORTS" \
            -j REDIRECT --to-ports "$TRANSPARENT_PORT"

        # Any nameserver the sandbox picks lands on our resolver. Matches the
        # hosted environment, where querying 1.1.1.1 or 8.8.8.8 both work.
        iptables -w -t nat -A PREROUTING -s "$SUBNET" -p udp --dport 53 \
            -j REDIRECT --to-ports "$DNS_PORT"
        iptables -w -t nat -A PREROUTING -s "$SUBNET" -p tcp --dport 53 \
            -j REDIRECT --to-ports "$DNS_PORT"

        echo "proxy: transparent capture on $CAPTURE_PORTS -> :$TRANSPARENT_PORT, dns -> :$DNS_PORT (src $SUBNET)"
    fi
fi

exec docker-entrypoint.sh "$@"
