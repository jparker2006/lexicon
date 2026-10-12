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
# 6. Every scripts/checks/*.sh, in name order, from the repo root. A new check
#    is a new file there, so it never edits this one. Each runs under a 300 s
#    limit and may set a tighter one with `limited` (scripts/lib/limits.sh).
#
# It runs in a build slot (scripts/lib/heavy.sh). The swift steps get the same
# flags (scripts/lib/swift-flags.sh) so the test build reuses the first build,
# and scripts/test.sh reuses both.
#
# Everything it prints also goes to .build/check.log, which ends with the step
# that failed, if one did, and "check exit N". When it ends it writes
# .build/check-summary.json (the commit, each step's result, the test count and
# the eval's worse list) and .build/check-stamp, one key=value per line:
#
#   sha=<HEAD when the check started>
#   tree=<the git tree of the files it checked, committed or not>
#   exit=<N, as in "check exit N">
#   finished=<UTC time>
#
# A commit whose tree is the stamp's was checked, so a builder can check, then
# commit, with no second check (scripts/ticket.sh reads it).
#
# Each step has a time limit, so a hang fails the check and says what was
# running instead of sitting silently. A cold build takes about 90 s in CI; every
# other step takes seconds.
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 0 ] || { echo "usage: scripts/check.sh" >&2; exit 64; }

. scripts/lib/heavy.sh
heavy scripts/check.sh
. scripts/lib/swift-flags.sh
. scripts/lib/limits.sh

mkdir -p .build
rm -f .build/check-stamp
sha=$(git rev-parse HEAD)
# The tree of the working files, from a scratch index so the real one is untouched.
tree=$(
    GIT_INDEX_FILE=$LIMITS_DIR/index
    export GIT_INDEX_FILE
    git read-tree HEAD && git add -A && git write-tree
) 2>/dev/null || tree=unknown

mkfifo "$LIMITS_DIR/out"
# A TERM to the whole group (a CI cancel) must not take tee before the last lines.
( trap '' TERM; exec tee .build/check.log < "$LIMITS_DIR/out" ) &
tee_pid=$!
exec > "$LIMITS_DIR/out" 2>&1

current=
results=
tests=null
failed=null
worse=null

# step <name> <seconds> <command> [args]
step() {
    current=$1
    seconds=$2
    shift 2
    echo "check: $current"
    limited "$seconds" "$@" || exit 1
    results="$results\"$current\": \"pass\", "
    current=
}

finish() {
    status=$?
    trap - EXIT
    events=$LIMITS_DIR/tests.events
    [ "$current" != tests ] || events=$LIMITS_EVENTS
    if [ -e "$events" ]; then
        tests="{\"run\": $(tests_started "$events"), \"failed\": $(tests_failed "$events")}"
    fi
    if [ "$status" -ne 0 ]; then
        name=${current:-scripts/check.sh}
        results="$results\"$name\": \"fail\", "
        failed="\"$name\""
        echo "check: failed: $name"
    fi
    if [ -e "$LIMITS_DIR/eval.json" ]; then
        worse=$(plutil -extract worse json -o - "$LIMITS_DIR/eval.json" 2>/dev/null) || worse=null
    fi
    printf '{"sha": "%s", "tree": "%s", "exit": %s, "failed": %s, "steps": {%s}, "tests": %s, "eval_worse": %s}\n' \
        "$sha" "$tree" "$status" "$failed" "${results%, }" "$tests" "$worse" > .build/check-summary.json
    printf 'sha=%s\ntree=%s\nexit=%s\nfinished=%s\n' "$sha" "$tree" "$status" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > .build/check-stamp
    echo "check exit $status"
    # tee ends once nothing holds the log's pipe open; a process a step left
    # behind could hold it forever, so give tee 10 s to drain and then stop it.
    exec >&- 2>&-
    ( sleep 10; kill -KILL "$tee_pid" 2>/dev/null ) &
    tee_limit=$!
    wait "$tee_pid" || true
    stop "$tee_limit"
    limits_cleanup
    exit "$status"
}
trap finish EXIT

# The scorer prints its report as JSON on stdout; it is kept for the worse list.
eval_fixture() {
    eval_status=0
    "$(swift build $SWIFT_FLAGS --show-bin-path)/lexicon-eval" --manifest scorer/fixtures/manifest.jsonl \
        --split everyday --baseline scorer/fixtures/wispr-baseline.jsonl --scripted-gold \
        > "$LIMITS_DIR/eval.json" || eval_status=$?
    cat "$LIMITS_DIR/eval.json"
    return "$eval_status"
}

step build 900 swift build $SWIFT_FLAGS
step "import check" 300 swift scripts/check-imports.swift
step tests 300 swift test $SWIFT_FLAGS --event-stream-output-path "$LIMITS_EVENTS" --event-stream-version 0
# Kept for the summary: the next step's limit clears the events file.
cp "$LIMITS_EVENTS" "$LIMITS_DIR/tests.events"
step "scorer tests" 300 scorer/test
step eval 300 eval_fixture
for check in scripts/checks/*.sh; do
    [ -e "$check" ] || continue
    step "$check" 300 sh "$check"
done
