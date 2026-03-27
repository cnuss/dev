#!/usr/bin/env bash
set -e

kubectl version --client
etcdctl version
k9s --help
fzf --version
kubectx --help
