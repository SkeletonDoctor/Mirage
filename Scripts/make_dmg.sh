#!/bin/bash
# Builds Mirage.app and packages it as build/Mirage-<version>.dmg with a drag-to-Applications layout.
# The app is signed ad hoc: without an Apple Developer ID it cannot be notarized, so other Macs
# need a one-time "Open Anyway" under System Settings > Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/build.sh
APP="build/Mirage.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Mirage-$VERSION.dmg"
STAGE="build/dmg-stage"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Mirage.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mirage" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
