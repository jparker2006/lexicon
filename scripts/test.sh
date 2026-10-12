#!/bin/sh
# test: run the tests, or some of them, the way scripts/check.sh does.
#
#   scripts/test.sh [--filter <regex>] [--repeat <n>] [--red <base>]
#
#   --filter <regex>  only the tests that match (swift test --filter). A run that
#                     matches no test fails: a check that ran nothing proves nothing.
#   --repeat <n>      run them n times, stopping at the first failing run (a flake).
#   --red <base>      red before green: run this branch's Tests against <base>'s
#                     Sources in a temporary worktree and print "red: N failed at
#                     <sha>". Exits 0 only when at least one test failed there.
#                     Each red run is a cold build; the shared tree is never touched.
#
# A bare `swift test` fails under Command Line Tools ("no such module Testing").
# This adds the flags check.sh uses (scripts/lib/swift-flags.sh), so it reuses
# check.sh's build products. It runs in a build slot (scripts/lib/heavy.sh), each
# run under a time limit that names the tests still running when it stops.
set -eu
cd "$(dirname "$0")/.."

usage() {
    echo "usage: scripts/test.sh [--filter <regex>] [--repeat <n>] [--red <base>]" >&2
    exit 64
}

filter=
repeat=1
red=
parse() {
    while [ $# -gt 0 ]; do
        [ $# -ge 2 ] || usage
        case $1 in
            --filter) filter=$2 ;;
            --repeat) case $2 in "" | *[!0-9]* | 0*) usage ;; esac; repeat=$2 ;;
            --red) red=$2 ;;
            *) usage ;;
        esac
        shift 2
    done
    [ -z "$red" ] || [ "$repeat" -eq 1 ] || usage
}
parse "$@"

. scripts/lib/heavy.sh
heavy scripts/test.sh "$@"
. scripts/lib/swift-flags.sh
. scripts/lib/limits.sh

worktree=
cleanup() {
    [ -z "$worktree" ] || git worktree remove --force "$worktree" || true
    limits_cleanup
}
trap cleanup EXIT

if [ -n "$red" ]; then
    base=$(git rev-parse --verify --quiet "$red^{commit}") || { echo "test: no commit '$red'" >&2; exit 64; }
    worktree=$LIMITS_DIR/red
    git worktree add --detach --quiet "$worktree" "$base"
    rm -rf "$worktree/Tests"
    cp -R Tests "$worktree/Tests"
    cd "$worktree"
fi

set --
[ -z "$filter" ] || set -- --filter "$filter"
built=0
limited 900 swift build $SWIFT_FLAGS --build-tests || built=$?
if [ "$built" -ne 0 ]; then
    [ -z "$red" ] || echo "red: the tests do not build at $(git rev-parse --short HEAD)" >&2
    exit "$built"
fi

run=1
while [ "$run" -le "$repeat" ]; do
    status=0
    limited 600 swift test $SWIFT_FLAGS --skip-build "$@" \
        --event-stream-output-path "$LIMITS_EVENTS" --event-stream-version 0 || status=$?
    if [ "$(tests_started "$LIMITS_EVENTS" 2>/dev/null || echo 0)" -eq 0 ]; then
        if [ "$status" -ne 0 ]; then
            echo "test: swift test failed (exit $status) before any test ran" >&2
        else
            echo "test: no test matched${filter:+ --filter $filter}" >&2
        fi
        exit 1
    fi
    if [ -n "$red" ]; then
        failed=$(tests_failed "$LIMITS_EVENTS")
        echo "red: $failed failed at $(git rev-parse --short HEAD)"
        [ "$failed" -gt 0 ] && exit 0 || exit 1
    fi
    if [ "$status" -ne 0 ]; then
        [ "$repeat" -eq 1 ] || echo "test: run $run of $repeat failed" >&2
        exit "$status"
    fi
    run=$((run + 1))
done
[ "$repeat" -eq 1 ] || echo "test: $repeat runs passed"
