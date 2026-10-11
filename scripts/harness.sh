#!/bin/sh
# harness: build and run lexicon-harness, which drives the installed Lexicon Dev
# through test hooks and the Accessibility API (#45).
#
#   scripts/dev-run.sh -- --test-hooks     install and launch the dev app with hooks on
#   scripts/harness.sh check               status item, windows, the target field
#   scripts/harness.sh hook status         one test hook, reply printed as JSON
#   scripts/harness.sh history [word]      History window: open time, copy, search, close
#
# The live-app lane: one builder at a time. The harness reads other apps, so it
# needs Accessibility, which it inherits from the terminal or agent app that runs
# it. It never touches the daily copy.
set -eu
cd "$(dirname "$0")/.."

# The same debug flags as scripts/check.sh and scripts/bundle.sh, so this reuses
# their build products. Sourced inside a function: it replaces "$@".
bin_path() {
    . scripts/lib/swift-flags.sh
    swift build --product lexicon-harness "$@" >&2
    swift build --show-bin-path "$@"
}
BIN="$(bin_path)/lexicon-harness"
exec "$BIN" "$@"
