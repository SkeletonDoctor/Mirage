#!/bin/bash
# Builds Mirage.app into ./build. Usage: Scripts/build.sh [--open | --install]
# --install also copies the app to /Applications and opens it from there.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
APP="build/Mirage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$BIN/Mirage" "$APP/Contents/MacOS/Mirage"

# Icon: render once, then reuse.
if [ ! -f build/AppIcon.icns ]; then
  swift Scripts/make_icon.swift build/icon-1024.png
  SET=build/AppIcon.iconset; rm -rf "$SET"; mkdir -p "$SET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2)); sips -z $d $d build/icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mirage</string>
  <key>CFBundleDisplayName</key><string>Mirage</string>
  <key>CFBundleIdentifier</key><string>app.mirage.local</string>
  <key>CFBundleExecutable</key><string>Mirage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2.4</string>
  <key>CFBundleVersion</key><string>8</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
if [ "${1:-}" = "--open" ]; then open "$APP"; fi
if [ "${1:-}" = "--install" ]; then
  rm -rf /Applications/Mirage.app
  cp -R "$APP" /Applications/Mirage.app
  echo "Installed /Applications/Mirage.app"
  open /Applications/Mirage.app
fi
