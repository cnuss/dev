#!/usr/bin/env python3
"""Enrich a Syft-generated SPDX SBOM with Homebrew package metadata."""

import json
import re
import sys


def normalize_license(license_info):
    """Convert Homebrew license format to SPDX expression."""
    if license_info is None:
        return "NOASSERTION"
    if isinstance(license_info, str):
        return license_info
    if isinstance(license_info, dict):
        if "any_of" in license_info:
            parts = [normalize_license(l) for l in license_info["any_of"]]
            return " OR ".join(parts)
        if "all_of" in license_info:
            parts = [normalize_license(l) for l in license_info["all_of"]]
            return " AND ".join(parts)
    return "NOASSERTION"


def spdx_id(name):
    """Create a valid SPDX identifier from a package name."""
    return f"SPDXRef-Package-brew-{re.sub(r'[^a-zA-Z0-9.-]', '-', name)}"


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <sbom.spdx.json> <brew.json> <output.spdx.json>",
              file=sys.stderr)
        sys.exit(1)

    sbom_path, brew_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(sbom_path) as f:
        sbom = json.load(f)

    with open(brew_path) as f:
        brew = json.load(f)

    existing = {p["name"] for p in sbom.get("packages", [])}
    packages = sbom.setdefault("packages", [])
    relationships = sbom.setdefault("relationships", [])
    added = 0

    for formula in brew.get("formulae", []):
        name = formula["name"]
        if name in existing:
            continue

        installed = formula.get("installed", [])
        version = installed[0]["version"] if installed else "unknown"
        homepage = formula.get("homepage", "NOASSERTION")
        license_expr = normalize_license(formula.get("license"))
        pkg_id = spdx_id(name)

        packages.append({
            "SPDXID": pkg_id,
            "name": name,
            "versionInfo": version,
            "supplier": "Organization: Homebrew",
            "downloadLocation": homepage or "NOASSERTION",
            "filesAnalyzed": False,
            "licenseConcluded": license_expr,
            "licenseDeclared": license_expr,
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:brew/{name}@{version}"
            }],
        })

        relationships.append({
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relatedSpdxElement": pkg_id,
            "relationshipType": "DESCRIBES",
        })

        added += 1

    print(f"Added {added} Homebrew package(s) to SBOM")

    with open(output_path, "w") as f:
        json.dump(sbom, f, indent=2)


if __name__ == "__main__":
    main()
