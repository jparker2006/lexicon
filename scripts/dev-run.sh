#!/bin/sh
# dev-run: build the dev app, install it to ~/Applications/Lexicon Dev.app and
# launch it with `open`. Never touches the daily copy (~/Applications/Lexicon.app).
#
#   scripts/dev-run.sh                       debug build
#   scripts/dev-run.sh --release             release build (for measuring budgets)
#   scripts/dev-run.sh [--release] -- ARGS   pass ARGS to the app, e.g. -- --test-hooks
#
# Launch with this (or `open`), never by running the binary: a binary run from a
# shell inherits the shell's Accessibility trust and fakes permissions, so the app
# refuses to start that way. Same certificate and bundle id every build, so the
# dev app keeps its Accessibility and Microphone grants across rebuilds.
#
# Only the live-app lane's holder runs this (scripts/live-lane.sh). Within it,
# a second lock stops two runs swapping the dev app at once.
set -eu
cd "$(dirname "$0")/.."
scripts/live-lane.sh check

RELEASE=
if [ "${1:-}" = --release ]; then RELEASE=--release; shift; fi
if [ "${1:-}" = -- ]; then shift; elif [ $# -gt 0 ]; then echo "usage: dev-run.sh [--release] [-- app args]" >&2; exit 64; fi

APP=$(scripts/bundle.sh dev $RELEASE)
exec lockf -k -t 600 "${TMPDIR:-/tmp}/dev.jparker.lexicon.dev.install.lock" scripts/lib/install-app.sh dev "$APP" "$@"
