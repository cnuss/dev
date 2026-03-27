#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

apt-get update
xargs apt-get install -y < "$SCRIPT_DIR/packages"
apt-get autoremove -y
apt-get clean -y
rm -rf /var/lib/apt/lists/*
