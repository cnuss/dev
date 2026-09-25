#!/usr/bin/env bash
set -euo pipefail

# Build-time, in `combined`: put the apt-kind stubs at their real paths
# (/usr/bin/xpra -> /usr/local/bin/ondemand). Release-kind stubs are already
# symlinks in /usr/local/bin, copied from the ondemand stage.
SHARE=/usr/local/share/ondemand

for lock in "$SHARE"/*.lock; do
    grep -q '^kind=apt$' "$lock" || continue
    (
        # shellcheck source=/dev/null
        . "$lock"
        # shellcheck disable=SC2154  # stubs comes from the lock
        for path in $stubs; do
            [ ! -e "$path" ] || { echo "$path exists, refusing to stub it" >&2; exit 1; }
            mkdir -p "$(dirname "$path")"
            ln -s /usr/local/bin/ondemand "$path"
        done
    )
done
