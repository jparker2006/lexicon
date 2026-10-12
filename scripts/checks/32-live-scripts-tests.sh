#!/bin/sh
# The live-lane, request, dev-run, dev-data and bench scripts' own tests
# (scripts/test-live/), each in a fake HOME with a fake gh: they never touch
# Lexicon Dev's real data, the lane lock, GitHub or Jake's daily copy.
set -eu
cd "$(dirname "$0")/../.."
failed=
for test in scripts/test-live/*.test.sh; do
    echo "== $test"
    sh "$test" || failed="$failed $test"
done
[ -z "$failed" ] || { echo "live scripts tests failed:$failed" >&2; exit 1; }
