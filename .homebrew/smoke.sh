#!/usr/bin/env bash
set -e

fzf --version
jose jwk gen -i '{"alg":"ES256"}' >/dev/null
jq --version
jwt --version
kubectl version --client
rg --version
uv --version
uvx --version
