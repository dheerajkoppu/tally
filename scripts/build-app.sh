#!/bin/bash
# Builds build.noindex/Tally.app from the Swift package, with the fan helper inside, and signs both ad hoc.
#   scripts/build-app.sh [release|debug]
# TALLY_SCRATCH_PATH and TALLY_APP set another build directory and app path, for parallel builds.
# TALLY_UNIVERSAL=1 builds for Apple silicon and Intel in one binary, as releases do.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
SCRATCH="${TALLY_SCRATCH_PATH:-.build}"
# The .noindex folder keeps test builds out of Spotlight, so only the installed copy shows up there.
APP="${TALLY_APP:-build.noindex/Tally.app}"
HELPER_LABEL="io.github.dheerajkoppu.tally.fanhelper"
# macOS ships bash 3.2, where an empty array trips set -u, hence the ${...+...} expansions below.
ARCHITECTURES=()
if [ "${TALLY_UNIVERSAL:-0}" = "1" ]; then
    ARCHITECTURES=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIGURATION" --scratch-path "$SCRATCH" ${ARCHITECTURES[@]+"${ARCHITECTURES[@]}"} --product Tally
swift build -c "$CONFIGURATION" --scratch-path "$SCRATCH" ${ARCHITECTURES[@]+"${ARCHITECTURES[@]}"} --product TallyFanHelper
BIN_PATH="$(swift build -c "$CONFIGURATION" --scratch-path "$SCRATCH" ${ARCHITECTURES[@]+"${ARCHITECTURES[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchServices"
cp "$BIN_PATH/Tally" "$APP/Contents/MacOS/Tally"
cp "$BIN_PATH/TallyFanHelper" "$APP/Contents/Library/LaunchServices/$HELPER_LABEL"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The Icon Composer document compiles to Assets.car (the layered icon for macOS 26 and later, plus flattened
# images) and AppIcon.icns (for earlier releases). Without Xcode's actool, the committed AppIcon.icns is used.
# actool works through a long-lived agent with its own working directory, so it gets absolute paths.
if [ -d Resources/AppIcon.icon ] && xcrun --find actool > /dev/null 2>&1; then
    APP_RESOURCES="$(cd "$APP/Contents/Resources" && pwd)"
    ICON_WORK="$(mktemp -d -t tally-icon)"
    xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$APP_RESOURCES" \
        --output-format human-readable-text --warnings --errors \
        --output-partial-info-plist "$ICON_WORK/partial.plist" \
        --app-icon AppIcon --platform macosx --target-device mac \
        --minimum-deployment-target 15.0 --standalone-icon-behavior all > "$ICON_WORK/actool.log" 2>&1 || true
    if grep -q "error:" "$ICON_WORK/actool.log" || [ ! -f "$APP_RESOURCES/Assets.car" ]; then
        cat "$ICON_WORK/actool.log"
        rm -rf "$ICON_WORK"
        exit 1
    fi
    grep "warning:" "$ICON_WORK/actool.log" || true
    rm -rf "$ICON_WORK"
elif [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# SwiftPM's default build system stamps the deployment target as the SDK version, which makes macOS 26 and later
# draw the app in the pre-Liquid Glass style. Restamp both binaries with the real SDK version.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
for BINARY in "$APP/Contents/MacOS/Tally" "$APP/Contents/Library/LaunchServices/$HELPER_LABEL"; do
    xcrun vtool -set-build-version macos 15.0 "$SDK_VERSION" -replace -output "$BINARY" "$BINARY"
done
# Nested code is signed first so the app's signature seals it.
codesign --force --sign - --identifier "$HELPER_LABEL" --options runtime "$APP/Contents/Library/LaunchServices/$HELPER_LABEL"
# The app refuses to install a fan helper whose hash doesn't match this one, sealed in by the app's signature.
HELPER_SHA256="$(shasum -a 256 "$APP/Contents/Library/LaunchServices/$HELPER_LABEL" | cut -d ' ' -f 1)"
/usr/libexec/PlistBuddy -c "Add :TallyFanHelperSHA256 string $HELPER_SHA256" "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements Resources/Tally.entitlements "$APP"
echo "Built $APP"
