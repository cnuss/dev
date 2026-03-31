#!/usr/bin/env python3
"""Convert an SPDX SBOM to a GitHub dependency snapshot and submit it."""

import json
import os
import sys
from datetime import datetime, timezone


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <sbom.spdx.json>", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1]) as f:
        sbom = json.load(f)

    resolved = {}
    for package in sbom.get("packages", []):
        purls = [
            ref["referenceLocator"]
            for ref in package.get("externalRefs", [])
            if ref.get("referenceType") == "purl"
        ]
        if purls:
            resolved[package["name"]] = {
                "package_url": purls[0],
                "relationship": "direct",
                "scope": "runtime",
            }

    snapshot = {
        "version": 0,
        "sha": os.environ["GITHUB_SHA"],
        "ref": os.environ["GITHUB_REF"],
        "job": {
            "correlator": f"sbom-{os.environ.get('GITHUB_JOB', 'unknown')}",
            "id": os.environ["GITHUB_RUN_ID"],
        },
        "scanned": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "detector": {
            "name": "cnuss/dev-sbom",
            "version": "1.0.0",
            "url": "https://github.com/cnuss/dev",
        },
        "manifests": {
            "container": {
                "name": "container",
                "resolved": resolved,
            }
        },
    }

    output = sys.argv[1].replace(".spdx.json", ".snapshot.json")
    with open(output, "w") as f:
        json.dump(snapshot, f, indent=2)

    print(f"Dependency snapshot written to {output} ({len(resolved)} packages)")


if __name__ == "__main__":
    main()
