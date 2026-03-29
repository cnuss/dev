#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

apt-get update
apt-get install -y ca-certificates curl

# Add apt sources from .ubuntu/sources/
install -m 0755 -d /etc/apt/keyrings
ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
for src in "$SCRIPT_DIR"/sources/*; do
    name="$(basename "$src")"
    . "$src"
    curl -fsSL "$gpg" -o "/etc/apt/keyrings/${name}.asc"
    chmod a+r "/etc/apt/keyrings/${name}.asc"
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/${name}.asc] ${uri} ${CODENAME} ${components}" > "/etc/apt/sources.list.d/${name}.list"
done

apt-get update
xargs apt-get install -y < "$SCRIPT_DIR/packages"
apt-get autoremove -y
apt-get clean -y
rm -rf /var/lib/apt/lists/*