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
set -eu
cd "$(dirname "$0")/.."

. scripts/lib/swift-flags.sh

swift build "$@"
swift scripts/check-imports.swift
swift test "$@"
scorer/test
"$(swift build "$@" --show-bin-path)/lexicon-eval" --manifest scorer/fixtures/manifest.jsonl --split everyday \
    --baseline scorer/fixtures/wispr-baseline.jsonl --scripted-gold
