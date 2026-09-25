#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkg/version/url/sha256/bins/debs… come from sourced .lock files
set -e

# SPDX 2.3 document for the on-demand packages, merged into the image SBOM by
# the sbom stage. The image only ships stubs, but every one of these is
# reachable at a pinned version and checksum, so list them, with a comment
# saying they're fetched on first use rather than present on disk. Apt
# packages list their whole .deb closure (deduplicated across packages).
COMMENT='Installed on first use by /usr/local/bin/ondemand; not present in the image until then.'

# name version url sha256 purl provides
spdx_pkg() {
    jq -n --arg name "$1" --arg version "$2" --arg url "$3" --arg sha256 "$4" \
          --arg purl "$5" --arg comment "$COMMENT${6:+ Provides: $6.}" \
    '{
      name: $name,
      SPDXID: ("SPDXRef-Package-ondemand-" + ("\($name)-\($version)" | gsub("[^A-Za-z0-9.-]"; "-"))),
      versionInfo: $version,
      downloadLocation: $url,
      filesAnalyzed: false,
      checksums: [{ algorithm: "SHA256", checksumValue: $sha256 }],
      licenseConcluded: "NOASSERTION",
      licenseDeclared: "NOASSERTION",
      copyrightText: "NOASSERTION",
      comment: $comment,
      externalRefs: [{ referenceCategory: "PACKAGE-MANAGER", referenceType: "purl", referenceLocator: $purl }]
    }'
}

uri() { jq -rn --arg s "$1" '$s | @uri'; }

for lock in "${1:?usage: sbom.sh <lock-share-dir>}"/*.lock; do
    (
        kind=release
        # shellcheck source=/dev/null
        . "$lock"
        if [ "$kind" = apt ]; then
            for d in "${debs[@]}"; do
                IFS='|' read -r name ver darch sha deb_url <<< "$d"
                case "$deb_url" in
                    *.ubuntu.com/*) purl="pkg:deb/ubuntu/$name@$(uri "$ver")?arch=$darch&distro=ubuntu-24.04" ;;
                    *) purl="pkg:generic/$name@$(uri "$ver")?download_url=$(uri "$deb_url")&checksum=sha256:$sha" ;;
                esac
                provides=""
                [[ " $packages " != *" $name "* ]] || provides="$bins"
                spdx_pkg "$name" "$ver" "$deb_url" "$sha" "$purl" "$provides"
            done
        else
            spdx_pkg "$pkg" "$version" "$url" "$sha256" \
                "pkg:generic/$pkg@$version?download_url=$(uri "$url")&checksum=sha256:$sha256" "$bins"
        fi
    )
done | jq -s --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg arch "$(dpkg --print-architecture)" '
  unique_by(.SPDXID) as $pkgs | {
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: "ondemand",
  documentNamespace: "https://github.com/cnuss/dev/ondemand/\($arch)/\($created)",
  creationInfo: { created: $created, creators: ["Tool: .ondemand/sbom.sh"] },
  packages: $pkgs,
  relationships: [$pkgs[] | {
    spdxElementId: "SPDXRef-DOCUMENT",
    relationshipType: "DESCRIBES",
    relatedSpdxElement: .SPDXID
  }]
}'
