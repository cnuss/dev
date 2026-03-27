#!/usr/bin/env bash
set -e

# ensure asdf can find tool versions regardless of HOME
[ -f /.tool-versions ] && cp /.tool-versions "$HOME/.tool-versions" 2>/dev/null || true

kubectl version --client
etcdctl version
k9s --help
fzf --version
kubectx --help
jq --version
yq --version

# verify asdf can install new tools
asdf plugin add ripgrep
asdf install ripgrep latest
