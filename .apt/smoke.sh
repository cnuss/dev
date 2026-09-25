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
ssh -V
node --version
npm --version
npx --version
pipx --version
# pipx venvs are built on Ubuntu's python3 (PIPX_DEFAULT_PYTHON), never a
# stray python3 a Homebrew formula might copy into /usr/local/bin.
[ "$(pipx environment --value PIPX_DEFAULT_PYTHON)" = /usr/bin/python3 ]
/usr/bin/python3 -c 'import venv, ensurepip'
