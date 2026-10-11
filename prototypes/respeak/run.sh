#!/bin/sh
# PROTOTYPE, throwaway. Builds, signs (ad-hoc) and opens the Re-speak prototype.
set -e
cd "$(dirname "$0")"
APP=build/RespeakProto.app
pkill -x RespeakProto 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/RespeakProto"
codesign --force --sign - "$APP"
open "$APP"
