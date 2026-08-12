#!/bin/sh
# Prove the sandbox is actually a sandbox. Run inside the workload container:
#
#   docker compose exec dev sandbox-verify
#
# Every check is an assertion about the boundary, not a smoke test of the
# image. A failure here means the confinement is weaker than advertised.
set -u

ALLOWED_HOST=${ALLOWED_HOST:-example.com}
DENIED_HOST=${DENIED_HOST:-example.org}
UNRESOLVABLE_HOST=${UNRESOLVABLE_HOST:-blocked.example.invalid}
PROXY=${HTTPS_PROXY:-http://proxy:8080}
STATUS_URL=${STATUS_URL:-http://proxy:8081/status}

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

head_ "1. No route off the sandbox network"

if ! command -v ip >/dev/null 2>&1; then
    printf '  SKIP  no iproute2 in this image\n'
elif [ -z "$(ip route show default 2>/dev/null)" ]; then
    ok "no default route (internal network, no NAT)"
else
    bad "a default route exists" "$(ip route show default)"
fi

out=$(curl -sS --noproxy '*' --max-time 5 https://1.1.1.1/ 2>&1)
if [ $? -ne 0 ]; then
    ok "direct HTTPS to a raw IP fails without the proxy"
else
    bad "direct HTTPS to 1.1.1.1 succeeded — egress is not confined" "$out"
fi

if ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    bad "ICMP to 8.8.8.8 succeeded — egress is not confined"
else
    ok "ICMP off-network fails"
fi

head_ "2. Allowed traffic goes through the proxy"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$ALLOWED_HOST/" 2>&1)
if [ "$code" = "200" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
    ok "https://$ALLOWED_HOST -> $code via $PROXY"
else
    bad "https://$ALLOWED_HOST returned '$code'" "is it in allowlist.txt?"
fi

if curl -s -o /dev/null --max-time 20 --cacert /certs/ca-cert.pem "https://$ALLOWED_HOST/"; then
    ok "chain verifies against the sandbox CA alone (TLS is re-terminated)"
else
    bad "the sandbox CA does not verify the connection" "expected MITM interception"
fi

head_ "3. Everything else is refused"

# A refused CONNECT surfaces two ways depending on the curl build: as the
# tunnel status in %{http_code}, or as "CONNECT tunnel failed, response 403"
# on stderr. Capture both and match either.
refusal() {
    curl -sS -o /dev/null -w ' http_code=%{http_code}' --max-time 20 "$@" 2>&1
}

for host in "$DENIED_HOST" "$UNRESOLVABLE_HOST"; do
    out=$(refusal "https://$host/")
    if echo "$out" | grep -q '403'; then
        ok "https://$host refused with 403"
    else
        bad "https://$host was not refused with 403" "$out"
    fi
done

out=$(refusal "https://$ALLOWED_HOST:8443/")
if echo "$out" | grep -q '403'; then
    ok "non-443 port refused with 403"
else
    bad "port 8443 was not refused" "$out"
fi

out=$(refusal --proxy "$PROXY" "http://$ALLOWED_HOST/")
if echo "$out" | grep -q '405'; then
    ok "plain-HTTP proxying refused with 405"
else
    bad "plain HTTP was not refused with 405" "$out"
fi

head_ "4. Diagnostics"

if curl -sS --noproxy '*' --max-time 5 "$STATUS_URL" >/dev/null 2>&1; then
    ok "proxy status endpoint reachable at $STATUS_URL"
else
    bad "proxy status endpoint unreachable at $STATUS_URL"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
