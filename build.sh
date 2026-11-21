#!/bin/bash
# Builds build/Dusk.app. Copy it to /Applications to keep it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Dusk.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos13.0 -o "$APP/Contents/MacOS/Dusk" Sources/Dusk.swift
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/" # regenerate with: swift Tools/make-icon.swift
codesign --force --sign - "$APP"
echo "Built $APP"
