#!/usr/bin/env bash
set -e

git --version
dig -v
command -v vtysh
/usr/lib/frr/bgpd --version
/usr/lib/frr/zebra --version
tcpdump --version
mtr --version
ncat --version
socat -V
nsenter --version
unshare --version
lsns --version
ssh -V
jq --version
jose jwk gen -i '{"alg":"ES256"}' >/dev/null
