#!/usr/bin/env bash
# shellcheck disable=SC2154  # kind/bins/stubs/sha256/url/version/debs come from sourced .lock files
set -e

# Structure only — nothing is downloaded, so this runs against the slim
# image too. smoke-tools.sh actually runs the tools.
SHARE=/usr/local/share/ondemand
SELF=/usr/local/bin/ondemand

command -v ondemand
ondemand list

fail() { echo "$*" >&2; exit 1; }
# Either still the stub, or already the real thing.
check_path() {
    [ -e "$1" ] || [ -L "$1" ] || fail "$1: missing"
    if [ -L "$1" ] && [ "$(readlink -f "$1")" = "$SELF" ]; then return 0; fi
    [ -x "$1" ] || fail "$1: neither a stub nor executable"
}

n=0
for lock in "$SHARE"/*.lock; do
    (
        kind=release
        # shellcheck source=/dev/null
        . "$lock"
        [ -n "$version" ] || fail "$lock: no version"
        if [ "$kind" = apt ]; then
            [ "${#debs[@]}" -gt 0 ] || fail "$lock: no debs"
            for d in "${debs[@]}"; do
                IFS='|' read -r name ver _ sha u <<< "$d"
                [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || fail "$lock: bad sha256 for $name"
                [[ "$u" == http*://* ]] || fail "$lock: bad url for $name"
                [ -n "$ver" ] || fail "$lock: no version for $name"
            done
            for path in $stubs; do check_path "$path"; done
        else
            [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || fail "$lock: bad sha256"
            [[ "$url" == https://* ]] || fail "$lock: bad url"
            for bin in $bins; do check_path "/usr/local/bin/$bin"; done
        fi
        for bin in $bins; do
            [ "$(readlink "$SHARE/bins/$bin")" = "../${lock##*/}" ] || fail "$bin: not mapped to ${lock##*/}"
        done
    )
    n=$((n + 1))
done
[ "$n" -gt 0 ] || fail "no on-demand packages registered"
