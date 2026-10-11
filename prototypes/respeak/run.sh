#!/bin/sh
# PROTOTYPE, throwaway. Builds, signs (ad-hoc) and opens the Re-speak prototype.
set -e
cd "$(dirname "$0")"
APP=build/RespeakProto.app
pkill -x RespeakProto 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/RespeakProto"
# Sign with the stable "Lexicon Dev" identity when present, so Accessibility survives rebuilds.
if security find-certificate -c "Lexicon Dev" >/dev/null 2>&1; then codesign --force --sign "Lexicon Dev" "$APP"; else codesign --force --sign - "$APP"; fi
open "$APP"
