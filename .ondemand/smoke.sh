#!/usr/bin/env bash
# shellcheck disable=SC2154  # sha256/url/version come from sourced .lock files
set -e

# Structure only — nothing is downloaded, so this runs against the slim
# image too. smoke-tools.sh actually runs the tools.
SHARE=/usr/local/share/ondemand

command -v ondemand
ondemand list

n=0
for link in "$SHARE"/bins/*; do
    bin="${link##*/}"
    lock="$SHARE/$(basename "$(readlink "$link")")"
    [ -f "$lock" ] || { echo "$bin: dangling lock link" >&2; exit 1; }
    # Either still the stub, or already swapped for the real binary.
    if [ -L "/usr/local/bin/$bin" ]; then
        [ "$(readlink "/usr/local/bin/$bin")" = ondemand ] || { echo "$bin: symlink not to ondemand" >&2; exit 1; }
    else
        [ -x "/usr/local/bin/$bin" ] || { echo "$bin: missing from /usr/local/bin" >&2; exit 1; }
    fi
    (
        # shellcheck source=/dev/null
        . "$lock"
        [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "$bin: bad sha256 in $lock" >&2; exit 1; }
        [[ "$url" == https://* ]] || { echo "$bin: bad url in $lock" >&2; exit 1; }
        [ -n "$version" ]
    )
    n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "no on-demand binaries registered" >&2; exit 1; }
