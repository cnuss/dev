#!/usr/bin/env bash
# shellcheck disable=SC2154  # kind/bins/stubs come from sourced .lock files
set -e

# Runs every on-demand tool. On a slim image the first call of each goes
# through its stub (install from $ONDEMAND_CACHE or the network, verify,
# install, exec); on :full they're already installed.
arch="$(dpkg --print-architecture)"

# release kind
cloudflared --version
etcd --version
etcdctl version
etcdutl version
fzf --version
k9s version -s
kubectl version --client
kubectx --version
kubens --version
prometheus --version
promtool --version
rg --version
step version
tailscale version
tailscaled --version
uv --version
uvx --version
yq --version
[ "$arch" != amd64 ] || jwt --version

# apt kind
bgpq4 -v
docker --version
nmap --version
node --version
npm --version
npx --version
pipx --version
# pipx venvs are built on Ubuntu's python3 (PIPX_DEFAULT_PYTHON).
[ "$(pipx environment --value PIPX_DEFAULT_PYTHON)" = /usr/bin/python3 ]
/usr/bin/python3 -c 'import venv, ensurepip'
xpra --version
# Xvfb has no --version; its usage text proves the real binary ran.
Xvfb -help 2>&1 | grep -q '^use: X'
command -v xvfb-run

# Every stub was replaced by the real thing…
for lock in /usr/local/share/ondemand/*.lock; do
    (
        kind=release
        # shellcheck source=/dev/null
        . "$lock"
        if [ "$kind" = apt ]; then paths="$stubs"; else paths=""; for b in $bins; do paths+=" /usr/local/bin/$b"; done; fi
        for p in $paths; do
            [ "$(readlink -f "$p")" != /usr/local/bin/ondemand ] || { echo "$p: still a stub after running" >&2; exit 1; }
        done
    )
done
# …so installing everything again is a no-op.
[ -z "$(ondemand install --all 2>&1)" ] || { echo "install --all not idempotent" >&2; exit 1; }
ondemand list | grep -v ' installed ' && { echo "packages not installed" >&2; exit 1; }

# The zsh completions the Homebrew stage used to ship for these.
completions="_k9s _kubectl _kubectx _kubens _rg _step _tailscale _uv _uvx _yq"
[ "$arch" != amd64 ] || completions+=" _jwt"
for f in $completions; do
    head -c 8 "/usr/local/share/zsh/site-functions/$f" | grep -q '^#compdef' \
        || { echo "missing completion $f" >&2; exit 1; }
done
