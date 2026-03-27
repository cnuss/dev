#!/usr/bin/env bash
set -e

source /etc/profile.d/asdf-tool-versions.sh

kubectl version --client
etcdctl version
k9s --help
fzf --version
kubectx --help
jq --version
yq --version
rg --version

# verify asdf can install new tools
asdf plugin add traefik
asdf install traefik latest
asdf set traefik latest
traefik version
