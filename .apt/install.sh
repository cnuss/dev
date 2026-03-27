#!/usr/bin/env bash

apt-get update && \
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
xargs apt-get install -y < "$SCRIPT_DIR/packages" && \
apt-get autoremove -y && \
apt-get clean -y && \
rm -rf /var/lib/apt/lists/* && \
usermod -l dev -d /home/dev -m ubuntu && \
groupmod -n dev ubuntu && \
echo "dev ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/dev && \
touch /home/dev/.sudo_as_admin_successful
