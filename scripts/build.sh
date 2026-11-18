#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project MockUsage.xcodeproj -scheme MockUsage -configuration Release \
  -derivedDataPath build/DerivedData build CODE_SIGNING_ALLOWED=NO
mkdir -p build
mock_stage=$(mktemp -d "${TMPDIR:-/tmp}/mockusage-build.XXXXXX")
trap 'rm -rf "$mock_stage"' EXIT
ditto --norsrc --noextattr build/DerivedData/Build/Products/Release/MockUsage.app "$mock_stage/MockUsage.app"
xattr -cr "$mock_stage/MockUsage.app"
# Remove linker debug maps containing developer home paths before signing.
strip -S "$mock_stage/MockUsage.app/Contents/MacOS/MockUsage"
strip -S "$mock_stage/MockUsage.app/Contents/PlugIns/MockUsageWidget.appex/Contents/MacOS/MockUsageWidget"
python3 scripts/audit-public.py --bundle "$mock_stage/MockUsage.app"
codesign --force --sign - --options runtime --entitlements Config/Widget.entitlements \
  "$mock_stage/MockUsage.app/Contents/PlugIns/MockUsageWidget.appex"
codesign --force --sign - --options runtime --entitlements Config/App.entitlements "$mock_stage/MockUsage.app"
codesign --verify --deep --strict "$mock_stage/MockUsage.app"
ditto -c -k --keepParent --norsrc --noextattr "$mock_stage/MockUsage.app" build/MockUsage.zip
echo "Built and signature-verified: $(pwd)/build/MockUsage.zip"
echo "Install with: bash scripts/install.sh"
