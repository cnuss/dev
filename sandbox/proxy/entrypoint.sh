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
