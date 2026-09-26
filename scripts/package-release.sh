#!/bin/bash
# Builds a universal release of Tally and zips it into dist/ for a GitHub release.
#   scripts/package-release.sh
# The version comes from CFBundleShortVersionString in Resources/Info.plist; bump it there first.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
APP="build.noindex/release/Tally.app"
# A fixed name lets https://github.com/dheerajkoppu/tally/releases/latest/download/Tally.zip always get the newest.
ZIP="dist/Tally.zip"

TALLY_UNIVERSAL=1 TALLY_SCRATCH_PATH=.build-release TALLY_APP="$APP" ./scripts/build-app.sh release
codesign --verify --deep --strict "$APP"

mkdir -p dist
rm -f "$ZIP"
# ditto keeps the bundle's symlinks and extended attributes, which zip would drop.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo
echo "Packaged Tally $VERSION as $ZIP"
shasum -a 256 "$ZIP"
echo
echo "To publish:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION $ZIP --title \"Tally $VERSION\" --generate-notes"
