#!/usr/bin/env bash
# Build-time, apt kind: for each .ondemand/tools/<pkg> with kind=apt, record
# the exact set of .debs that installing its `packages` would add to this
# image (run FROM the bins stage, so "this image" is what ships):
#
#   $OUT/share/<pkg>.lock    packages, stub paths, debs=(name|version|arch|sha256|url ...)
#   $OUT/share/bins/<bin>    -> ../<pkg>.lock
#   $OUT/cache/<deb>         the downloads (smoke test + :full only)
#
# Stubs are the packages' own /usr/bin, /usr/sbin, /bin, /sbin entries (plus
# any `stubs=` extras): symlinks to the ondemand script at the real path,
# which dpkg replaces with the real file on install. Paths that already
# exist in the image are never stubbed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: lock-apt.sh <out-dir>}"
mkdir -p "$OUT/share/bins" "$OUT/cache"

apt-get update -qq

# Verify a download against the hash apt printed ("SHA256:…", "MD5Sum:…"),
# which chains back to the signed Release file.
check_apt_hash() {
    local file="$1" spec="$2" algo="${2%%:*}" want="${2#*:}" got
    case "$algo" in
        SHA512) got="$(sha512sum "$file")" ;;
        SHA256) got="$(sha256sum "$file")" ;;
        SHA1)   got="$(sha1sum "$file")" ;;
        MD5Sum) got="$(md5sum "$file")" ;;
        *) echo "unknown hash type in '$spec'" >&2; return 1 ;;
    esac
    [ "${got%% *}" = "$want" ] || { echo "${file##*/}: $algo mismatch" >&2; return 1; }
}

for manifest in "$SCRIPT_DIR"/tools/*; do
    pkg="${manifest##*/}"
    (
        kind="" packages="" stubs=""
        # shellcheck source=/dev/null
        . "$manifest"
        [ "$kind" = apt ] || exit 0

        # shellcheck disable=SC2086  # word-split the package list
        uris="$(apt-get install -y --no-install-recommends --print-uris -qq $packages)"
        [ -n "$uris" ] || { echo "$pkg: nothing to install — already baked?" >&2; exit 1; }

        debs=()
        declare -A deb_of=()
        while read -r url file _size hash; do
            url="${url//\'/}"
            dest="$OUT/cache/$file"
            [ -f "$dest" ] || curl -fsSL --retry 3 -o "$dest" "$url"
            check_apt_hash "$dest" "$hash"
            # shellcheck disable=SC2016  # dpkg expands ${Package} etc., not the shell
            read -r name ver darch < <(dpkg-deb --show --showformat='${Package} ${Version} ${Architecture}\n' "$dest")
            debs+=("$name|$ver|$darch|$(sha256sum "$dest" | cut -d' ' -f1)|$url")
            deb_of[$name]="$dest"
        done <<< "$uris"

        # Stub every executable the top-level packages put on PATH.
        stub_paths=()
        for p in $packages; do
            [ -n "${deb_of[$p]:-}" ] || { echo "$pkg: $p not in its own closure" >&2; exit 1; }
            while read -r path; do
                stub_paths+=("$path")
            done < <(dpkg-deb -c "${deb_of[$p]}" \
                | awk '{ print $6 }' | sed 's|^\./|/|' \
                | grep -E '^/(usr/)?s?bin/[^/]+$' || true)
        done
        # Extra stubs (executables that live in a dependency, not the
        # top-level package) must really be installed by this closure.
        for path in $stubs; do
            found=""
            for deb in "${deb_of[@]}"; do
                if dpkg-deb -c "$deb" | awk '{ print $6 }' | sed 's|^\./|/|' | grep -qxF "$path"; then
                    found=1; break
                fi
            done
            [ -n "$found" ] || { echo "$pkg: stub $path isn't in any of its debs" >&2; exit 1; }
            stub_paths+=("$path")
        done
        kept=()
        for path in "${stub_paths[@]}"; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                echo "$pkg: $path already in the image, not stubbed" >&2
                continue
            fi
            kept+=("$path")
        done
        [ "${#kept[@]}" -gt 0 ] || { echo "$pkg: no executables to stub" >&2; exit 1; }

        first="${packages%% *}"
        version=""
        for d in "${debs[@]}"; do
            IFS='|' read -r name ver _ <<< "$d"
            [ "$name" = "$first" ] && version="$ver"
        done

        bins=""
        for path in "${kept[@]}"; do bins+="${bins:+ }${path##*/}"; done
        {
            printf 'pkg=%q\nkind=apt\nversion=%q\npackages=%q\nbins=%q\nstubs=%q\n' \
                "$pkg" "$version" "$packages" "$bins" "${kept[*]}"
            printf 'debs=(\n'
            printf '    %q\n' "${debs[@]}"
            printf ')\n'
        } > "$OUT/share/$pkg.lock"

        for bin in $bins; do
            ln -sfn "../$pkg.lock" "$OUT/share/bins/$bin"
        done
        echo "$pkg $version: ${#debs[@]} debs, stubs: $bins" >&2
    )
done

rm -rf /var/lib/apt/lists/*
