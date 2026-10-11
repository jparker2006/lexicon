#!/bin/sh
# check: every check a change must pass, the same locally and in CI.
#
#   scripts/check.sh
#
# 1. swift build with the explicit target dependency import check as an error.
# 2. scripts/check-imports.swift for transitive imports and banned modules.
# 3. swift test.
#
# Under Command Line Tools (ADR 0003), SwiftPM does not find Swift Testing on its
# own, so the build and test steps add its framework and rpath flags. Both steps
# get the same flags so the test build reuses the first build.
set -eu
cd "$(dirname "$0")/.."

CLT=/Library/Developer/CommandLineTools
set -- --explicit-target-dependency-import-check error
if [ "$(xcode-select -p)" = "$CLT" ]; then
    set -- "$@" \
        -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib"
fi

swift build "$@"
swift scripts/check-imports.swift
swift test "$@"
