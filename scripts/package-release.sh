#!/bin/bash
# Builds a universal release of Tally, signs it with a Developer ID certificate, has Apple notarize it, and zips
# it into dist/ for a GitHub release.
#   scripts/package-release.sh
# The version comes from CFBundleShortVersionString in Resources/Info.plist; bump it there first.
# TALLY_SIGNING_IDENTITY names another certificate; "-" signs ad hoc and skips notarization, for forks.
# TALLY_NOTARY_PROFILE names the notarytool keychain profile, saved once with:
#   xcrun notarytool store-credentials tally-notary --apple-id <Apple ID> --team-id <team ID>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)"
APP="build.noindex/release/Tally.app"
# A fixed name lets https://github.com/dheerajkoppu/tally/releases/latest/download/Tally.zip always get the newest.
ZIP="dist/Tally.zip"
SIGNING_IDENTITY="${TALLY_SIGNING_IDENTITY:-Developer ID Application: Dheeraj Koppu (4L5DB8NN2V)}"
NOTARY_PROFILE="${TALLY_NOTARY_PROFILE:-tally-notary}"

# Missing credentials stop the release here rather than after the build.
if [ "$SIGNING_IDENTITY" != "-" ]; then
    if ! security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
        echo "No \"$SIGNING_IDENTITY\" certificate in the keychain." >&2
        echo "Set TALLY_SIGNING_IDENTITY to yours, or to - for an ad hoc build that macOS will warn about." >&2
        exit 1
    fi
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
        echo "The notarytool keychain profile \"$NOTARY_PROFILE\" is missing or no longer signs in. Save it with:" >&2
        echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id <team ID>" >&2
        exit 1
    fi
fi

package() {
    mkdir -p dist
    rm -f "$ZIP"
    # ditto keeps the bundle's symlinks and extended attributes, which zip would drop.
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
}

TALLY_UNIVERSAL=1 TALLY_SCRATCH_PATH=.build-release TALLY_APP="$APP" TALLY_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
    ./scripts/build-app.sh release
codesign --verify --deep --strict "$APP"
package

if [ "$SIGNING_IDENTITY" != "-" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    # The stapled ticket lets the app open without a warning even offline, so the zip is remade to carry it.
    xcrun stapler staple "$APP"
    package
    spctl --assess --type execute --verbose "$APP"
fi

echo
echo "Packaged Tally $VERSION as $ZIP"
shasum -a 256 "$ZIP"
echo
echo "To publish:"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION $ZIP --title \"Tally $VERSION\" --generate-notes"
