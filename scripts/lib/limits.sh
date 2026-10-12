# Sourced, not run. Time limits for the steps of scripts/check.sh,
# scripts/test.sh and scripts/checks/*.sh, so a hang fails the step and says
# what was running instead of sitting silently.
#
#   limited <seconds> <command> [args]   runs a command; fails it past the limit
#   stop <pid>                           stops a process and everything it started
#   LIMITS_EVENTS                        pass to `swift test --event-stream-output-path`
#                                        so a timeout names the unfinished tests
#
# Sets an INT/TERM trap; a caller with its own EXIT trap calls limits_cleanup.

LIMITS_DIR=$(mktemp -d -t limits)
LIMITS_EVENTS=$LIMITS_DIR/events
limits_step=
limits_watchdog=
# A background step ignores Ctrl-C, so stop it here.
trap 'stop "$limits_step"; stop "$limits_watchdog"; exit 130' INT TERM

limits_cleanup() { rm -rf "$LIMITS_DIR"; }

# Children first. By parent PID, not process group: SwiftPM starts its test
# runner in a group of its own.
stop() {
    [ -n "$1" ] || return 0
    for child in $(pgrep -P "$1"); do stop "$child"; done
    kill -TERM "$1" 2>/dev/null || true
}

# On a timeout it names the tests that started and never ended, from Swift
# Testing's event stream: unlike the console output, that is written as each
# event happens, so a killed run loses none of it. Returns the command's status,
# or 1 on a timeout.
limited() {
    limits_seconds=$1
    shift
    rm -f "$LIMITS_EVENTS" "$LIMITS_DIR/timeout"
    "$@" &
    limits_step=$!
    ( sleep "$limits_seconds" && : > "$LIMITS_DIR/timeout" && stop "$limits_step" ) &
    limits_watchdog=$!
    limits_status=0
    wait "$limits_step" || limits_status=$?
    stop "$limits_watchdog"
    limits_step=
    limits_watchdog=
    if [ "$limits_status" -ne 0 ] && [ -e "$LIMITS_DIR/timeout" ]; then
        echo "limits: stopped after $limits_seconds s: $*" >&2
        if [ -e "$LIMITS_EVENTS" ]; then
            unfinished_tests "$LIMITS_EVENTS" | sed 's/^/limits: unfinished test: /' >&2
        fi
        return 1
    fi
    return "$limits_status"
}

# The IDs of tests in a Swift Testing event stream that started and never ended.
unfinished_tests() {
    sed -n 's/.*"kind":"testStarted".*"testID":"\([^"]*\)".*/\1/p' "$1" | sort > "$LIMITS_DIR/started"
    sed -n 's/.*"kind":"testEnded".*"testID":"\([^"]*\)".*/\1/p' "$1" | sort > "$LIMITS_DIR/ended"
    comm -23 "$LIMITS_DIR/started" "$LIMITS_DIR/ended" | sed 's|\\/|/|g'
}

# Counts over an event stream, of test functions only: a suite is a test too,
# but its ID has no "(".
tests_started() {
    grep '"kind":"testStarted"' "$1" | grep -c '"testID":"[^"]*(' || true
}

# A failed test, or one that started and never ended: the runner crashed in it
# or was stopped.
tests_failed() {
    ended=$(grep '"kind":"testEnded"' "$1" | grep '"testID":"[^"]*(' | grep -c '"symbol":"fail"' || true)
    echo $(( ended + $(unfinished_tests "$1" | grep -c '(' || true) ))
}
