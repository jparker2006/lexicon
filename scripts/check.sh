#!/bin/sh
# check: every check a change must pass, the same locally and in CI.
#
#   scripts/check.sh
#
# 1. swift build with the explicit target dependency import check as an error.
# 2. scripts/check-imports.swift for transitive imports and banned modules.
# 3. swift test.
#
# Both steps get the same flags (scripts/lib/swift-flags.sh, which also adds
# Swift Testing's paths under Command Line Tools) so the test build reuses the
# first build.
set -eu
cd "$(dirname "$0")/.."

. scripts/lib/swift-flags.sh

swift build "$@"
swift scripts/check-imports.swift
swift test "$@"
