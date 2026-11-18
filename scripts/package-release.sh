#!/bin/bash
# Package an already built, locally signed app for manual distribution.
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)"/\1/p' project.yml)
architecture=universal
mkdir -p dist
archive="MockUsage-$version-macos-$architecture.zip"
cp build/MockUsage.zip "dist/$archive"
(cd dist && shasum -a 256 "$archive" > "$archive.sha256")
echo "Release archive: dist/$archive"
echo "This local build is ad-hoc signed, not Developer ID signed or notarized."
