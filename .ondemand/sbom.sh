#!/usr/bin/env bash
# shellcheck disable=SC2154  # pkg/version/url/sha256/bins come from sourced .lock files
set -e

# SPDX 2.3 document for the on-demand packages, merged into the image SBOM by
# the sbom stage. The image only ships stubs, but every one of these is
# reachable at a pinned version and checksum, so list them — with a comment
# saying they're fetched on first use rather than present on disk.
SHARE="${1:?usage: sbom.sh <lock-share-dir>}"

for lock in "$SHARE"/*.lock; do
    (
        # shellcheck source=/dev/null
        . "$lock"
        jq -n --arg pkg "$pkg" --arg version "$version" --arg url "$url" \
              --arg sha256 "$sha256" --arg bins "$bins" \
        '{
          name: $pkg,
          SPDXID: "SPDXRef-Package-ondemand-\($pkg)",
          versionInfo: $version,
          downloadLocation: $url,
          filesAnalyzed: false,
          checksums: [{ algorithm: "SHA256", checksumValue: $sha256 }],
          licenseConcluded: "NOASSERTION",
          licenseDeclared: "NOASSERTION",
          copyrightText: "NOASSERTION",
          comment: "Installed on first use by /usr/local/bin/ondemand (provides: \($bins)); not present in the image until then.",
          externalRefs: [{
            referenceCategory: "PACKAGE-MANAGER",
            referenceType: "purl",
            referenceLocator: "pkg:generic/\($pkg)@\($version)?download_url=\($url | @uri)&checksum=sha256:\($sha256)"
          }]
        }'
    )
done | jq -s --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg arch "$(dpkg --print-architecture)" '{
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: "ondemand",
  documentNamespace: "https://github.com/cnuss/dev/ondemand/\($arch)/\($created)",
  creationInfo: { created: $created, creators: ["Tool: .ondemand/sbom.sh"] },
  packages: .,
  relationships: [.[] | {
    spdxElementId: "SPDXRef-DOCUMENT",
    relationshipType: "DESCRIBES",
    relatedSpdxElement: .SPDXID
  }]
}'
