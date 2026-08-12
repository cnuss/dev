#!/bin/sh
# Prove the sandbox behaves like the hosted environment. Run inside the
# workload container:
#
#   docker compose exec dev sandbox-verify
#
# Every check is an assertion about the boundary, not a smoke test of the
# image. The expectations track what the hosted environment actually does,
# measured rather than assumed:
#
#   TCP :80/:443  intercepted and re-terminated, whatever the client config
#   UDP :53       answered, whichever nameserver the client aimed at
#   ICMP          dropped
#   other ports   dropped
#
# Policy checks (403 on an unlisted host) only run when allowlist.txt is in
# deny-by-default mode — with `*` present they are skipped, not failed.
set -u

ALLOWED_HOST=${ALLOWED_HOST:-example.com}
DENIED_HOST=${DENIED_HOST:-example.org}
PROXY=${HTTPS_PROXY:-http://proxy:8080}
RESOLVER=${SANDBOX_RESOLVER:-172.31.240.10}
GATEWAY=${SANDBOX_GATEWAY:-172.31.240.10}
STATUS_URL=${STATUS_URL:-http://proxy:8081/status}

pass=0
fail=0
skip=0

ok()   { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
skip_(){ skip=$((skip + 1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
head_(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# Is the policy open? Ask the proxy rather than reading the file, so this
# tracks what is actually loaded.
policy=$(curl -s --noproxy '*' --max-time 5 "$STATUS_URL" 2>/dev/null)
if echo "$policy" | grep -q '"\*"'; then
    OPEN_POLICY=1
else
    OPEN_POLICY=0
fi

head_ "1. The sandbox has no independent path out"

if ! command -v ip >/dev/null 2>&1; then
    skip_ "no iproute2 in this image"
elif ip route show default 2>/dev/null | grep -q "$GATEWAY"; then
    ok "default route points at the proxy ($GATEWAY)"
else
    bad "default route does not go via $GATEWAY" "$(ip route show default 2>&1)"
fi

# The network is routable (it has to be, for capture to work), so the
# confinement rests on there being no NAT for this subnet. Route around the
# proxy to the bridge gateway and confirm it is a dead end.
if ! command -v ip >/dev/null 2>&1 || ! command -v nc >/dev/null 2>&1; then
    skip_ "need iproute2 and netcat to test the no-NAT property"
else
    bridge_gw=$(echo "$GATEWAY" | sed 's/\.[0-9]*$/.1/')
    ip route add 1.1.1.1/32 via "$bridge_gw" 2>/dev/null || true
    if timeout 8 nc -z -w 5 1.1.1.1 443 >/dev/null 2>&1; then
        bad "reached the internet via the bridge gateway $bridge_gw" \
            "the sandbox subnet is being masqueraded — check enable_ip_masquerade"
    else
        ok "routing around the proxy is a dead end (no NAT for this subnet)"
    fi
    ip route del 1.1.1.1/32 via "$bridge_gw" 2>/dev/null || true
fi

# ICMP is dropped in the hosted environment too — nothing off-host answers.
if ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    bad "ICMP to 8.8.8.8 succeeded — the hosted environment drops it"
else
    ok "ICMP off-network is dropped"
fi

# Only :80, :443 and :53 are captured; everything else has nowhere to go.
# (/dev/tcp is a bash builtin and this runs under sh, so use nc.)
if ! command -v nc >/dev/null 2>&1; then
    skip_ "no netcat in this image"
elif timeout 8 nc -z -w 5 1.1.1.1 22 >/dev/null 2>&1; then
    bad "TCP :22 to a public IP connected — only :80/:443 should be captured"
else
    ok "uncaptured ports (:22) go nowhere"
fi

head_ "2. Name resolution is answered by the proxy"

if grep -q "nameserver ${RESOLVER}" /etc/resolv.conf 2>/dev/null; then
    ok "resolv.conf points at the proxy ($RESOLVER)"
else
    bad "resolv.conf does not point at $RESOLVER" "$(cat /etc/resolv.conf 2>&1)"
fi

if getent hosts "$ALLOWED_HOST" >/dev/null 2>&1; then
    ok "$ALLOWED_HOST resolves"
else
    bad "$ALLOWED_HOST does not resolve" "check 'docker compose logs proxy'"
fi

# The hosted environment answers whichever resolver you aim at; the redirect
# reproduces that by capturing :53 to any destination.
if command -v nslookup >/dev/null 2>&1; then
    if timeout 8 nslookup "$ALLOWED_HOST" 1.1.1.1 >/dev/null 2>&1; then
        ok "queries aimed at 1.1.1.1 are captured and answered"
    else
        bad "a query to 1.1.1.1 was not answered" "the :53 redirect is not working"
    fi
else
    skip_ "no nslookup in this image"
fi

head_ "3. Traffic is intercepted and re-terminated"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$ALLOWED_HOST/" 2>&1)
if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
    ok "https://$ALLOWED_HOST -> $code via $PROXY"
else
    bad "https://$ALLOWED_HOST returned '$code'"
fi

if curl -s -o /dev/null --max-time 20 --cacert /certs/ca-cert.pem "https://$ALLOWED_HOST/"; then
    ok "chain verifies against the sandbox CA alone (TLS is re-terminated)"
else
    bad "the sandbox CA does not verify the connection" "expected interception"
fi

# The point of the transparent tier: a client that ignores HTTPS_PROXY is
# captured anyway, exactly as in the hosted environment.
code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 20 "https://$ALLOWED_HOST/" 2>&1)
if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
    ok "a proxy-unaware client is transparently intercepted -> $code"
else
    bad "proxy-unaware HTTPS returned '$code'" "the :443 redirect is not working"
fi

code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 20 "http://$ALLOWED_HOST/" 2>&1)
if [ -n "$code" ] && [ "$code" != "000" ]; then
    ok "proxy-unaware plain HTTP is transparently intercepted -> $code"
else
    bad "proxy-unaware HTTP got no response" "the :80 redirect is not working"
fi

head_ "4. Policy enforcement"

if [ "$OPEN_POLICY" = "1" ]; then
    skip_ "allowlist is open ('*'), matching the hosted environment"
    skip_ "remove '*' from allowlist.txt to enforce deny-by-default"
else
    out=$(curl -sS -o /dev/null -w ' http_code=%{http_code}' --max-time 20 "https://$DENIED_HOST/" 2>&1)
    if echo "$out" | grep -q '403'; then
        ok "https://$DENIED_HOST refused with 403"
    else
        bad "https://$DENIED_HOST was not refused" "$out"
    fi

    if getent hosts "$DENIED_HOST" >/dev/null 2>&1; then
        bad "$DENIED_HOST resolved — the resolver is not filtering"
    else
        ok "$DENIED_HOST does not resolve (no DNS exfiltration path)"
    fi

    out=$(curl -sS -o /dev/null -w ' http_code=%{http_code}' --max-time 20 --proxy "$PROXY" "http://$ALLOWED_HOST/" 2>&1)
    if echo "$out" | grep -q '405'; then
        ok "explicit plain-HTTP proxying refused with 405"
    else
        bad "explicit plain HTTP was not refused with 405" "$out"
    fi
fi

head_ "5. Diagnostics"

if curl -sS --noproxy '*' --max-time 5 "$STATUS_URL" >/dev/null 2>&1; then
    ok "proxy status endpoint reachable at $STATUS_URL"
else
    bad "proxy status endpoint unreachable at $STATUS_URL"
fi

printf '\n%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
