#!/bin/bash
# Builds build/Dusk.app, a universal app (Apple silicon and Intel).
#   ./build.sh                                   ad-hoc signed, for running on this Mac
#   SIGN_IDENTITY="Developer ID Application: …" ./build.sh
#                                                signed for distribution, ready to notarize (release.sh does this)
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

APP=build/Dusk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Dusk" "$APP/Contents/MacOS/Dusk"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" # regenerate with: swift Tools/make-icon.swift Resources/AppIcon.icns
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Sign from the inside out: Sparkle's helpers, then the framework, then the app.
IDENTITY="${SIGN_IDENTITY:--}"
SIGN=(codesign --force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then SIGN+=(--options runtime --timestamp); fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed with: $IDENTITY)"
