#!/bin/bash
# Builds the indicator prototype into a .app and launches it. Extra args go to the app.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/build/LexiconIndicator.app"
NAME=LexiconIndicator

pkill -x "$NAME" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 6 "$DIR/main.swift" -o "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.lexicon.prototype.indicator</string>
  <key>CFBundleName</key><string>Lexicon Indicator</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

if security find-identity -v -p codesigning | grep -q "Lexicon Dev"; then
  codesign --force -s "Lexicon Dev" "$APP"
else
  codesign --force -s - "$APP"
fi

open "$APP" --args "$@"
