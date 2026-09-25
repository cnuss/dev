#!/usr/bin/env bash
set -e

git --version
dig -v
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
