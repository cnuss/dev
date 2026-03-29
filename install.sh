#!/usr/bin/env bash
set -e

KUBECTL_VERSION="v1.35.0"
ETCD_VERSION="v3.6.6"
ASDF_VERSION="v0.18.1"

FEATURE_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCH="$(dpkg --print-architecture)"

# Phase 1: Ubuntu base packages + profile.d
"$FEATURE_DIR/.ubuntu/install.sh"

# Phase 2: asdf + tools (requires Go to build asdf from source)
apt-get update
apt-get install -y golang make
rm -rf /var/lib/apt/lists/*

export PATH="$HOME/.asdf/shims:$HOME/go/bin:${PATH}"
"$FEATURE_DIR/.asdf/install.sh"

# Relocate asdf to system-wide paths (mirrors Dockerfile COPY --from=asdf)
cp "$HOME/go/bin/asdf" /usr/local/bin/asdf
mkdir -p /.asdf
cp -a "$HOME/.asdf/installs" /.asdf/installs
cp -a "$HOME/.asdf/plugins" /.asdf/plugins
cp -a "$HOME/.asdf/shims" /.asdf/shims
cp "$HOME/.tool-versions" /.tool-versions

# Cleanup Go and build artifacts
apt-get purge -y golang make
apt-get autoremove -y
rm -rf "$HOME/go" "$HOME/.asdf"

# Phase 3: Claude CLI
"$FEATURE_DIR/.claude/install.sh"
cp "$HOME/.local/bin/claude" /usr/local/bin/claude

# Phase 4: kubectl + etcdctl (replaces Dockerfile COPY --from external images)
curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl
chmod +x /usr/local/bin/kubectl

ETCD_TARBALL="etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz"
curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/${ETCD_TARBALL}" -o "/tmp/${ETCD_TARBALL}"
tar xzf "/tmp/${ETCD_TARBALL}" -C /tmp "etcd-${ETCD_VERSION}-linux-${ARCH}/etcdctl"
mv "/tmp/etcd-${ETCD_VERSION}-linux-${ARCH}/etcdctl" /usr/local/bin/etcdctl
chmod +x /usr/local/bin/etcdctl
rm -rf "/tmp/${ETCD_TARBALL}" "/tmp/etcd-${ETCD_VERSION}-linux-${ARCH}"

# Phase 5: final cleanup
apt-get clean -y
rm -rf /var/lib/apt/lists/*
