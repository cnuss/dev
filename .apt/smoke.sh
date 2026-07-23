#!/usr/bin/env bash
set -e

git --version
dig -v
docker --version
command -v vtysh
/usr/lib/frr/bgpd --version
/usr/lib/frr/zebra --version
tcpdump --version
mtr --version
nmap --version
ncat --version
socat -V
bgpq4 -v
nsenter --version
unshare --version
lsns --version
