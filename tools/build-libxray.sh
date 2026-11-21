#!/bin/bash
# Builds Vendor/LibXray.xcframework (iOS device + simulator) from XTLS/libXray at a pinned release.
# Needs macOS with Xcode, git, python3 and Go 1.27+ on PATH.
set -euo pipefail
TAG=v26.11.9
# Pinned like the tag's own go.mod: the same gomobile/gobind and the same Go toolchain every time
# (upstream's build otherwise takes «latest» gomobile and re-resolves modules).
export LIBXRAY_GOMOBILE_VERSION=v0.0.0-20261011034528-197770444867
export GOTOOLCHAIN=go1.27.4
export GOFLAGS=-mod=mod
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${TMPDIR:-/tmp}/libxray-$TAG
rm -rf "$WORK"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/XTLS/libXray.git "$WORK"
cd "$WORK"
# iPhone and iPad only (device + simulator), iOS 17 minimum.
sed -i '' 's/"ios,iossimulator,macos,maccatalyst"/"ios,iossimulator"/; s/"15.0"/"17.0"/' build/app/apple_gomobile.py
python3 build/main.py apple gomobile
# The modules linked are exactly the tag's go.sum: a build that re-resolved anything stops here.
git diff --exit-code --stat go.mod go.sum || { echo "libXray $TAG: go.mod/go.sum changed during the build - not reproducible" >&2; exit 1; }
mkdir -p "$ROOT/Vendor"
rm -rf "$ROOT/Vendor/LibXray.xcframework"
cp -R LibXray.xcframework "$ROOT/Vendor/"
echo "Vendor/LibXray.xcframework from libXray $TAG (Xray-core $TAG), gomobile $LIBXRAY_GOMOBILE_VERSION, $(go version)"
echo "Work tree kept for tools/licenses.sh: $WORK"
