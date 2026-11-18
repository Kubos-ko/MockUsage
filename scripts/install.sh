#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x MockUsage >/dev/null; then
  echo "Quit Mock Usage before installing a new build."
  exit 1
fi
mkdir -p "$HOME/Applications"
ditto -x -k build/MockUsage.zip "$HOME/Applications"
codesign --verify --deep --strict "$HOME/Applications/MockUsage.app"
# macOS can keep the previous extension executable alive across in-place updates.
# Re-register this bundle and stop only our extension so WidgetKit loads the new code.
/usr/bin/pluginkit -a "$HOME/Applications/MockUsage.app/Contents/PlugIns/MockUsageWidget.appex"
pkill -TERM -x MockUsageWidget || true
open "$HOME/Applications/MockUsage.app"
