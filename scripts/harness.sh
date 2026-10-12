#!/bin/sh
# harness: build and run lexicon-harness, which drives the installed Lexicon Dev
# through test hooks and the Accessibility API (#45, #156).
#
#   scripts/dev-run.sh -- --test-hooks       install and launch the dev app with hooks on
#                                            (its data in a scratch folder; add --dev-data for its own)
#   scripts/harness.sh check                 status item, windows, the target field
#   scripts/harness.sh paste-check           paste through the real path, clipboard restored
#   scripts/harness.sh hook status           one test hook, reply printed as JSON
#   scripts/harness.sh hook dictate <wav> [--result-delay <ms>]   dictate a WAV through the live path
#   scripts/harness.sh hook fn down|up... [--shift]   fn edges through the tap's own handler
#   scripts/harness.sh hook key esc | sleep | mic zeros   Esc, the Mac sleeping, a silent mic next
#   scripts/harness.sh hook indicator <state> [message]   show one pill state
#   scripts/harness.sh hook sound <cue>      play one sound, reply with its latency
#   scripts/harness.sh hook privacy on|off [--always-private <ids>]   Private mode and the always-private apps
#   scripts/harness.sh pill [--shots <dir>]  every pill state checked, sounds timed
#   scripts/harness.sh history [word]        History window: open time, copy, search, close
#   scripts/harness.sh relaunch [--release] [--test-hooks [--dev-data]]   warm relaunch, launch timings
#   scripts/harness.sh wait-fn [--count n] [--timeout s]   Dictation outcomes from the log (real fn)
#   scripts/harness.sh fixture <text>        a 16 kHz WAV of <text>; prints its path
#   scripts/harness.sh stats <file>          n, p50, p95, max of a saved sample
#   scripts/harness.sh run-checklist <file>  run a checklist, print the table and a Live checks: body
#   scripts/harness.sh result <issue> <branch> <sha>   the Live checks: body for the last run
#
# Only the live-app lane's holder runs this (scripts/live-lane.sh). The harness
# reads other apps, so it needs Accessibility, which it inherits from the
# terminal or agent app that runs it. It never touches the daily copy. Output
# never holds dictated or typed text, only its length and hash.
set -eu
cd "$(dirname "$0")/.."
scripts/live-lane.sh check
. scripts/lib/fn-listeners.sh

# Other apps answering fn, by name and pid, or nothing. Every result header records it.
LEXICON_FN_LISTENERS=$(fn_listeners_line | sed 's/^fn listeners: //; s/^none$//')
export LEXICON_FN_LISTENERS
case "${1:-}" in
check) warn_fn_listeners ;;
# Real fn presses reach every listener, and another's paste reads as typing in Dev.
# The fn and key hooks reach only Dev's own tap, so they run either way.
wait-fn) require_no_fn_listeners || exit 1 ;;
esac

# The same debug flags as scripts/check.sh and scripts/bundle.sh, so this reuses
# their build products.
bin_path() {
    . scripts/lib/swift-flags.sh
    swift build --product lexicon-harness $SWIFT_FLAGS >&2
    swift build --show-bin-path $SWIFT_FLAGS
}
BIN="$(bin_path)/lexicon-harness"
exec "$BIN" "$@"
