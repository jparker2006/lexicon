#!/bin/sh
# bundle: build, assemble and sign Lexicon.app from the SwiftPM products (ADR 0003).
#
#   scripts/bundle.sh dev              debug build as "Lexicon Dev"
#   scripts/bundle.sh dev --release    release build as "Lexicon Dev" (for measuring budgets)
#   scripts/bundle.sh daily            release build as "Lexicon"
#
# Prints the signed bundle's path (under .build/bundle/) as its last line.
# Installs nothing: scripts/dev-run.sh and scripts/install.sh do that.
#
# Signed with the self-signed "Lexicon Dev" certificate (override with
# LEXICON_SIGN_IDENTITY), Hardened Runtime on. The designated requirement then
# names the bundle id and the certificate, not this binary's hash, so every
# rebuild is the same app to macOS and keeps its Accessibility and Microphone
# grants. The script fails rather than produce a bundle whose grants would not
# carry over.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/flavor.sh

flavor "${1:-}"
CONFIG=debug
[ "$FLAVOR" = daily ] && CONFIG=release
[ "${2:-}" = --release ] && CONFIG=release
IDENTITY=${LEXICON_SIGN_IDENTITY:-Lexicon Dev}

if [ "$CONFIG" = debug ]; then
    . scripts/lib/swift-flags.sh
else
    set -- --explicit-target-dependency-import-check error
fi
swift build --product LexiconApp -c "$CONFIG" "$@" >&2
BIN="$(swift build -c "$CONFIG" --show-bin-path "$@")/LexiconApp"

APP=".build/bundle/$CONFIG/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Lexicon"
[ "$CONFIG" = release ] && strip -x "$APP/Contents/MacOS/Lexicon"

PLIST="$APP/Contents/Info.plist"
cp scripts/app/Info.plist "$PLIST"
COMMIT=$(git rev-parse --short HEAD)
git diff --quiet HEAD -- Sources Package.swift Package.resolved scripts || COMMIT="$COMMIT-dirty"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"
plutil -replace CFBundleName -string "$NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$NAME" "$PLIST"
plutil -replace CFBundleVersion -string "$(git rev-list --count HEAD)" "$PLIST"
plutil -replace LexiconCommit -string "$COMMIT" "$PLIST"
if grep -q FILLED_BY_BUNDLE_SH "$PLIST"; then
    echo "bundle: Info.plist still has an unfilled key" >&2
    exit 1
fi

codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
    --entitlements scripts/app/Lexicon.entitlements "$APP" >&2
codesign --verify --strict "$APP"

# Grants survive rebuilds only if the designated requirement is the bundle id
# plus the certificate. An ad-hoc or hash-only requirement would lose them.
DR=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
case "$DR" in
    "identifier \"$BUNDLE_ID\" and certificate "*) ;;
    *)
        echo "bundle: designated requirement is '$DR'; grants would not survive a rebuild" >&2
        exit 1
        ;;
esac

echo "$APP"
