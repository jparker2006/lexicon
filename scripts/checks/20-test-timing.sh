#!/bin/sh
# 20-test-timing: the timing lint (scripts/check-tests.swift) over Tests,
# scripts and lexicon-eval. A test that sleeps, races a short real
# deadline or blocks a thread waiting fails here, before review.
set -eu
cd "$(dirname "$0")/../.."
exec swift scripts/check-tests.swift
