#!/bin/sh
# install: build a release of Jake's daily Lexicon, swap it into
# ~/Applications/Lexicon.app and relaunch it. The one update command; there is
# no auto-updater. Never touches the dev copy (~/Applications/Lexicon Dev.app).
#
#   scripts/install.sh
#
# If a Dictation is in progress, the running copy finishes it before it quits,
# and this waits. Same certificate and bundle id every install, so Lexicon keeps
# its Accessibility and Microphone grants.
set -eu
cd "$(dirname "$0")/.."

[ $# -eq 0 ] || { echo "usage: install.sh" >&2; exit 64; }
APP=$(scripts/bundle.sh daily | tail -n 1)
echo "Installing Lexicon $(plutil -extract LexiconCommit raw "$APP/Contents/Info.plist")" >&2
exec lockf -t 600 "${TMPDIR:-/tmp}/dev.jparker.lexicon.install.lock" scripts/lib/install-app.sh daily "$APP"
