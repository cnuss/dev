#!/usr/bin/env bash
set -e

cloudflared --version
etcdctl version
fzf --version
jose jwk gen -i '{"alg":"ES256"}' >/dev/null
jq --version
jwt --version
k9s version -s
kubectl version --client
kubectx --version
rg --version
step version
tailscale version
yq --version
