#!/bin/bash
# After `xcodegen generate`: the Swift packages resolve exactly as in tools/Package.resolved
# (command-line builds add -disableAutomaticPackageResolution so nothing is re-resolved).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D="$ROOT/IPBrowser.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$D" && cp "$ROOT/tools/Package.resolved" "$D/Package.resolved"
echo "Swift packages pinned: $(grep -c '"identity"' "$D/Package.resolved")"
