#!/usr/bin/env bash
set -e

# Runs every on-demand tool. On a slim image the first call of each goes
# through the stub (install from $ONDEMAND_CACHE or the network, verify,
# swap, exec); on :full they're already installed.
cloudflared --version
etcd --version
etcdctl version
etcdutl version
k9s version -s
kubectx --version
kubens --version
prometheus --version
promtool --version
step version
tailscale version
tailscaled --version
yq --version

# Every stub was replaced by the real binary…
for link in /usr/local/share/ondemand/bins/*; do
    bin="${link##*/}"
    [ ! -L "/usr/local/bin/$bin" ] || { echo "$bin: still a stub after running" >&2; exit 1; }
done
# …so installing everything again is a no-op.
[ -z "$(ondemand install --all 2>&1)" ] || { echo "install --all not idempotent" >&2; exit 1; }
ondemand list | grep -v ' installed ' && { echo "packages not installed" >&2; exit 1; }

# The zsh completions the Homebrew stage used to ship for these.
for f in _k9s _kubectx _kubens _step _tailscale _yq; do
    head -c 8 "/usr/local/share/zsh/site-functions/$f" | grep -q '^#compdef' \
        || { echo "missing completion $f" >&2; exit 1; }
done
