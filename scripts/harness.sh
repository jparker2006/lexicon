#!/bin/sh
# harness: build and run lexicon-harness, which drives the installed Lexicon Dev
# through test hooks and the Accessibility API (#45).
#
#   scripts/dev-run.sh -- --test-hooks       install and launch the dev app with hooks on
#   scripts/harness.sh check                 status item, windows, the target field
#   scripts/harness.sh hook status           one test hook, reply printed as JSON
#   scripts/harness.sh hook dictate <wav>    dictate a WAV through the live path
#   scripts/harness.sh hook indicator <state> [message]   show one pill state
#   scripts/harness.sh hook sound <cue>      play one sound, reply with its latency
#   scripts/harness.sh pill [--shots <dir>]  every pill state checked, sounds timed
#   scripts/harness.sh history [word]        History window: open time, copy, search, close
#
# Only the live-app lane's holder runs this (scripts/live-lane.sh). The harness
# reads other apps, so it needs Accessibility, which it inherits from the
# terminal or agent app that runs it. It never touches the daily copy.
set -eu
cd "$(dirname "$0")/.."
scripts/live-lane.sh check

# The same debug flags as scripts/check.sh and scripts/bundle.sh, so this reuses
# their build products. Sourced inside a function: it replaces "$@".
bin_path() {
    . scripts/lib/swift-flags.sh
    swift build --product lexicon-harness "$@" >&2
    swift build --show-bin-path "$@"
}
BIN="$(bin_path)/lexicon-harness"
exec "$BIN" "$@"
