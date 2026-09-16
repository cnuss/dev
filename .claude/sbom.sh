#!/usr/bin/env bash
set -e

# SPDX 2.3 document for the claude binary, merged into the image SBOM by the
# sbom stage. Syft has nothing to catalog here — it's one Bun-compiled
# executable — so describe it from the installed artifact itself.
BIN=/usr/local/bin/claude
BASE_URL="https://downloads.claude.ai/claude-code-releases"

case "$(uname -m)" in
    x86_64|amd64)  platform="linux-x64" ;;
    aarch64|arm64) platform="linux-arm64" ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

version="$("$BIN" --version | cut -d' ' -f1)"
sha256="$(sha256sum "$BIN" | cut -d' ' -f1)"
url="$BASE_URL/$version/$platform/claude"

jq -n \
    --arg version "$version" \
    --arg sha256 "$sha256" \
    --arg url "$url" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
'{
  spdxVersion: "SPDX-2.3",
  dataLicense: "CC0-1.0",
  SPDXID: "SPDXRef-DOCUMENT",
  name: "claude",
  documentNamespace: $url,
  creationInfo: {
    created: $created,
    creators: ["Tool: .claude/sbom.sh"]
  },
  packages: [{
    name: "claude-code",
    SPDXID: "SPDXRef-Package-claude-code",
    versionInfo: $version,
    supplier: "Organization: Anthropic",
    downloadLocation: $url,
    filesAnalyzed: false,
    checksums: [{ algorithm: "SHA256", checksumValue: $sha256 }],
    licenseConcluded: "NOASSERTION",
    licenseDeclared: "NOASSERTION",
    copyrightText: "NOASSERTION",
    externalRefs: [{
      referenceCategory: "PACKAGE-MANAGER",
      referenceType: "purl",
      referenceLocator: "pkg:generic/claude-code@\($version)?download_url=\($url | @uri)&checksum=sha256:\($sha256)"
    }]
  }],
  relationships: [{
    spdxElementId: "SPDXRef-DOCUMENT",
    relationshipType: "DESCRIBES",
    relatedSpdxElement: "SPDXRef-Package-claude-code"
  }]
}'
