#!/bin/sh
# check: every check a change must pass, the same locally and in CI.
#
#   scripts/check.sh
#
# 1. swift build with the explicit target dependency import check as an error.
# 2. scripts/check-imports.swift for transitive imports and banned modules.
# 3. swift test.
# 4. scorer/test, the scorer's own tests (needs uv).
# 5. lexicon-eval on the public fixture manifest with a fake engine that hears
#    the gold: the pipeline, the run file and the scorer's report end to end,
#    which must not be worse than the fixture's Wispr-like baseline.
#
# The swift steps get the same flags (scripts/lib/swift-flags.sh, which also adds
# Swift Testing's paths under Command Line Tools) so the test build reuses the
# first build.
#
# Each step has a time limit, so a hang fails the check and says what was
# running instead of sitting silently. A cold build takes about 90 s in CI; every
# other step takes seconds.
set -eu
cd "$(dirname "$0")/.."

. scripts/lib/swift-flags.sh

log=$(mktemp -t check)
trap 'rm -f "$log" "$log".*' EXIT

# Stops a process and everything it started, children first. By parent PID, not
# process group: SwiftPM starts its test runner in a group of its own.
stop() {
    for child in $(pgrep -P "$1"); do stop "$child"; done
    kill -TERM "$1" 2>/dev/null || true
}

# Runs a step, failing it once it passes its limit in seconds. On a timeout it
# names the tests that started and never finished, from Swift Testing's output.
limited() {
    seconds=$1
    shift
    rm -f "$log".*
    ( { status=0; "$@" || status=$?; echo "$status" > "$log.status"; } 2>&1 | tee "$log" ) &
    step=$!
    ( sleep "$seconds"; : > "$log.timeout"; stop "$step" ) &
    watchdog=$!
    wait "$step" || true
    stop "$watchdog"
    if [ -e "$log.timeout" ]; then
        echo "check: stopped after ${seconds} s, still running: $*" >&2
        sed -n 's/.* Test \(.*\) started\.$/\1/p' "$log" | grep -vx run | sort > "$log.started"
        sed -n -E 's/.* Test (.*) (with [0-9]+ test cases? )?(passed|failed) after .*/\1/p; s/.* Test (.*) skipped.*/\1/p' "$log" |
            sort > "$log.ended"
        comm -23 "$log.started" "$log.ended" | sed 's/^/check: unfinished test: /' >&2
        exit 1
    fi
    return "$(cat "$log.status")"
}

limited 900 swift build "$@"
limited 300 swift scripts/check-imports.swift
limited 300 swift test "$@"
limited 300 scorer/test
limited 300 "$(swift build "$@" --show-bin-path)/lexicon-eval" --manifest scorer/fixtures/manifest.jsonl --split everyday \
    --baseline scorer/fixtures/wispr-baseline.jsonl --scripted-gold
