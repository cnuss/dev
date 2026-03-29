#!/usr/bin/env bash
set -e

curl -fsSL https://claude.ai/install.sh | bash
cp "$(readlink -f /root/.local/bin/claude)" /usr/local/bin/claude
