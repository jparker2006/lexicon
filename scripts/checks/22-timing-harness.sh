#!/bin/sh
# 22-timing-harness: the timing lint over lexicon-harness. scripts/check-tests.swift
# (#160) fails on blocking waits and speed-dependent timing; the harness drives a
# live app, so it is held to the same rule: every child process through
# runChild (Sources/LexiconHarness/ChildProcess.swift), never waitUntilExit.
# Skips, saying so, until that script exists.
set -eu
cd "$(dirname "$0")/../.."
if [ ! -f scripts/check-tests.swift ]; then
    echo "22-timing-harness: skipped, scripts/check-tests.swift is not here yet (#160)"
    exit 0
fi
exec swift scripts/check-tests.swift Sources/LexiconHarness
