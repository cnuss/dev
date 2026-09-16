#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_URL="https://downloads.claude.ai/claude-code-releases"

# Same release layout claude.ai/install.sh reads, minus the launcher/shell
# setup it runs afterwards — the binary is self-contained.
case "$(uname -m)" in
    x86_64|amd64)  platform="linux-x64" ;;
    aarch64|arm64) platform="linux-arm64" ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# .claude/version is "latest" or a pinned x.y.z
version="$(tr -d '[:space:]' < "$SCRIPT_DIR/version")"
if [ "$version" = "latest" ]; then
    version="$(curl -fsSL "$BASE_URL/latest")"
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    echo "bad version: $version" >&2
    exit 1
fi

checksum="$(curl -fsSL "$BASE_URL/$version/manifest.json" | jq -r ".platforms[\"$platform\"].checksum // empty")"
if [[ ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
    echo "no checksum for $platform in $version manifest" >&2
    exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL -o "$tmp" "$BASE_URL/$version/$platform/claude"
echo "$checksum  $tmp" | sha256sum -c --quiet
install -m 0755 "$tmp" /usr/local/bin/claude
