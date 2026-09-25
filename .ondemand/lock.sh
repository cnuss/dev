#!/usr/bin/env bash
# Build-time: resolve every .ondemand/tools/<pkg> manifest for this arch and
# write what the runtime stub needs into $OUT:
#
#   $OUT/share/<pkg>.lock        version, url, sha256, bins, completions
#   $OUT/share/bins/<bin>        -> ../<pkg>.lock (which package owns a bin)
#   $OUT/bin/<bin>               -> ondemand (the stub, lands in /usr/local/bin)
#   $OUT/cache/<artifact>        the downloads (smoke test + :full only)
#
# "latest" is resolved here, not at run time, so an image always installs
# exactly what it was built and smoke-tested with. The weekly no-cache
# rebuild moves versions forward.
# shellcheck disable=SC2154  # repo/bins/tag come from the sourced manifest
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: lock.sh <out-dir>}"

arch="$(dpkg --print-architecture)"   # amd64 | arm64
uname_m="$(uname -m)"                  # x86_64 | aarch64
export arch uname_m

mkdir -p "$OUT/share/bins" "$OUT/bin" "$OUT/cache"

github_latest() {
    local url
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest")"
    [[ "$url" == */releases/tag/* ]] || { echo "no latest release for $1 ($url)" >&2; return 1; }
    echo "${url##*/tag/}"
}

# Download $1 into the cache (once) and print its sha256.
fetch() {
    local file="$OUT/cache/${1##*/}"
    [ -f "$file" ] || curl -fsSL --retry 3 -o "$file" "$1"
    sha256sum "$file" | cut -d' ' -f1
}

# Cross-check against the upstream checksum file when the manifest names
# one: either "<sha>  <file>" lines or a bare hash.
check_upstream() {
    local url="$1" artifact="$2" want="$3" sums got
    sums="$(curl -fsSL --retry 3 "$url")"
    got="$(awk -v f="$artifact" '$2 == f || $2 == "*" f { print $1; exit }' <<< "$sums")"
    if [ -z "$got" ] && [[ "$sums" =~ ^[0-9a-f]{64}[[:space:]]*$ ]]; then
        got="${sums%%[[:space:]]*}"
    fi
    [ -n "$got" ] || { echo "$artifact not listed in $url" >&2; return 1; }
    [ "$got" = "$want" ] || { echo "$artifact: sha256 $want, upstream says $got" >&2; return 1; }
}

for manifest in "$SCRIPT_DIR"/tools/*; do
    pkg="${manifest##*/}"
    (
        tag="" kind=""
        # shellcheck source=/dev/null
        . "$manifest"
        [ "$kind" != apt ] || exit 0   # lock-apt.sh handles these
        # Only published for some arches (arches="amd64" etc.): no stub here.
        if [ -n "${arches:-}" ] && [[ " $arches " != *" $arch "* ]]; then
            echo "$pkg: not available on $arch, skipped" >&2
            exit 0
        fi
        if [ -z "$tag" ]; then
            if declare -F latest >/dev/null; then
                tag="$(latest)"
            else
                tag="$(github_latest "$repo")"
            fi
        fi
        version="${tag#v}"
        artifact_url="$(url)"
        sha="$(fetch "$artifact_url")"
        if declare -F checksums >/dev/null; then
            check_upstream "$(checksums)" "${artifact_url##*/}" "$sha"
        fi

        lock="$OUT/share/$pkg.lock"
        {
            printf 'pkg=%q\nversion=%q\nurl=%q\nsha256=%q\nbins=%q\n' \
                "$pkg" "$version" "$artifact_url" "$sha" "$bins"
            [ -z "${repo:-}" ] || printf 'repo=%q\n' "$repo"
            for bin in $bins; do
                cmd_var="complete_$bin"
                url_fn="complete_url_$bin"
                if declare -F "$url_fn" >/dev/null; then
                    curl_url="$("$url_fn")"
                    printf 'complete_url_%s=%q\ncomplete_sha256_%s=%q\n' \
                        "$bin" "$curl_url" "$bin" "$(fetch "$curl_url")"
                elif [ -n "${!cmd_var:-}" ]; then
                    printf 'complete_%s=%q\n' "$bin" "${!cmd_var}"
                fi
            done
        } > "$lock"

        for bin in $bins; do
            ln -sfn "../$pkg.lock" "$OUT/share/bins/$bin"
            ln -sfn ondemand "$OUT/bin/$bin"
        done
        echo "$pkg $version ($arch) $sha" >&2
    )
done
