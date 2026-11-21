#!/bin/bash
# What CI runs, and what to run before a pull request (macOS with Xcode, XcodeGen, Go; shellcheck if present):
# the server scripts' lint, then the app's build and unit tests on an iOS simulator.
#   tools/ci.sh [simulator name or id]      (DERIVED=<dir> puts Xcode's build products there)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
bash -n Server/install.sh Server/test/lifecycle.sh tools/*.sh
if command -v shellcheck >/dev/null; then shellcheck -x Server/install.sh Server/test/lifecycle.sh tools/*.sh; fi
# The console command in the docs fetches exactly this installer: its checksum and the tag named after it.
SUM=$(shasum -a 256 Server/install.sh 2>/dev/null || sha256sum Server/install.sh); SUM=${SUM%% *}
for doc in README.md README.ru.md docs/SERVER.md; do
  if ! grep -q "installer-${SUM:0:12}/Server/install.sh" "$doc" || ! grep -q "$SUM  ipb.sh" "$doc"; then
    echo "$doc: the console command does not match Server/install.sh (sha256 $SUM)" >&2; exit 1
  fi
done
[ -d Vendor/LibXray.xcframework ] || tools/build-libxray.sh
xcodegen generate --quiet
tools/pin-packages.sh
DEST=${1:-}
if [ -z "$DEST" ]; then   # the first available iPhone simulator
  DEST=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" in runtime:
        for d in devices:
            if d["name"].startswith("iPhone"):
                print(d["udid"]); sys.exit()')
fi
case "$DEST" in *-*-*-*-*) DEST="id=$DEST" ;; *) DEST="platform=iOS Simulator,name=$DEST" ;; esac
xcodebuild test -project IPBrowser.xcodeproj -scheme IPBrowser -configuration Debug -destination "$DEST" \
  ${DERIVED:+-derivedDataPath "$DERIVED"} -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= -parallel-testing-enabled NO
