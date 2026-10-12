#!/bin/sh
# scripts/lib/heavy.sh's own tests: the build slots' queue, the third slot, the
# quiet run and the core split, on slot files in a fake HOME with the real
# lockf. Nothing sleeps: each job says it holds a slot on a FIFO, a holder lets
# go only when the test writes to its release FIFO, and a waiter's line is read
# from another FIFO. The verdict is forced with LEXICON_MACHINE_VERDICT.
#
#   sh scripts/test-heavy/heavy.test.sh [name-filter]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
CORES=$(sysctl -n hw.ncpu)
total=0
failed=0

# Each test runs in its own subshell with a fresh HOME and FIFOs. Job control
# (set -m) gives each job its own process group, so cleanup stops a job's
# lockf and command with it.
setup() {
    T=$(mktemp -d "${TMPDIR:-/tmp}/test-heavy.XXXXXX")
    export HOME="$T/home"
    mkdir -p "$HOME"
    unset HEAVY_SLOT HEAVY_JOBS LEXICON_MACHINE_VERDICT
    export HEAVY_POLL=0.2
    SLOTS="$HOME/Library/Application Support/Lexicon Dev/heavy"
    PIDS=
    set -m
    mkfifo "$T/events" "$T/waits" "$T/readings"
    # Opened read-write, so a job's write never blocks on the test.
    exec 3<> "$T/events" 4<> "$T/waits" 5<> "$T/readings"
    # The verdict's page-out reading, once per try at slot 3: each call says
    # so on the readings FIFO, so the test can count a waiter's tries.
    mkdir "$T/bin"
    printf '#!/bin/sh\necho reading > "%s/readings"\necho "Pageouts: 0."\n' "$T" > "$T/bin/vm_stat"
    chmod +x "$T/bin/vm_stat"
    export PATH="$T/bin:$PATH"
    trap cleanup EXIT
}

cleanup() {
    for p in $PIDS; do kill -TERM -- "-$p" 2> /dev/null || true; done
    for p in $PIDS; do wait "$p" 2> /dev/null || true; done
    rm -rf "$T"
}

fail() {
    echo "  $*"
    exit 1
}

# job NAME [--quiet]: starts a job in a build slot. Holding it, the job writes
# "NAME HEAVY_SLOT HEAVY_JOBS" to the events FIFO, then waits for a line on
# $T/release.NAME. Its pid is $NAME.
job() {
    name=$1
    shift
    mkfifo "$T/release.$name"
    scripts/lib/heavy.sh "$@" sh -c 'echo "$1 $HEAVY_SLOT $HEAVY_JOBS" > "$2/events"; read -r x < "$2/release.$1"' job "$name" "$T" 2>&4 &
    eval "$name=\$!"
    PIDS="$PIDS $!"
}

# expect_event "NAME SLOT JOBS": the next job to take a slot is that one.
# timing-ok: the 30 s read limit here and in expect_wait only bounds a hang;
# every wait ends on the job's own line, never on time.
expect_event() {
    read -r -t 30 got <&3 || fail "no job took a slot; expected '$1'"
    [ "$got" = "$1" ] || fail "expected '$1' to take a slot, got '$got'"
}

# expect_wait TEXT: the next waiter's line says TEXT.
expect_wait() {
    read -r -t 30 got <&4 || fail "no wait line; expected one with '$1'"
    case "$got" in *"$1"*) ;; *) fail "wait line lacks '$1': $got" ;; esac
}

release() {
    echo > "$T/release.$1"
    eval "wait \$$1" || fail "job $1 exited $?"
}

held() {
    st=0
    lockf -k -s -n -t 0 "$SLOTS/slot$1" true 2> /dev/null || st=$?
    [ "$st" -eq 75 ]
}

# Slots 1 and 2 held by H1 and H2.
hold_two() {
    job H1
    expect_event "H1 1 $CORES"
    job H2
    expect_event "H2 2 $((CORES / 2))"
}

test_waiters_take_slots_in_the_order_they_came() {
    export LEXICON_MACHINE_VERDICT=no
    hold_two
    # A tries least often, so a B or C allowed to jump the line would win.
    export HEAVY_POLL=1
    job A
    expect_wait "number 1 in line"
    export HEAVY_POLL=0.05
    job B
    expect_wait "number 2 in line"
    job C
    expect_wait "number 3 in line"
    release H1
    expect_event "A 1 $((CORES / 2))"
    release H2
    expect_event "B 2 $((CORES / 2))"
    release A
    expect_event "C 1 $((CORES / 2))"
    release B
    release C
}

test_a_wait_line_names_the_holders() {
    export LEXICON_MACHINE_VERDICT=no
    hold_two
    job A
    expect_wait "slot 1: "
    case "$got" in *"running sh -c"*"slot 2: "*"running sh -c"*"slot 3: free"*) ;; *) fail "holders not named: $got" ;; esac
    release H1
    expect_event "A 1 $((CORES / 2))"
    release A
    release H2
}

test_a_waiter_that_dies_drops_out_of_line() {
    export LEXICON_MACHINE_VERDICT=no
    hold_two
    job A
    expect_wait "number 1 in line"
    job B
    expect_wait "number 2 in line"
    kill -KILL -- "-$A"
    wait "$A" 2> /dev/null || true
    kill -0 "$A" 2> /dev/null && fail "A is still alive"
    release H1
    expect_event "B 1 $((CORES / 2))"
    release B
    release H2
}

test_the_third_slot_opens_while_the_mac_has_room() {
    hold_two
    export LEXICON_MACHINE_VERDICT=yes
    job J
    expect_event "J 3 $((CORES / 3))"
    release J
    release H1
    release H2
}

test_a_slot_probe_never_opens_the_third_slot() {
    export LEXICON_MACHINE_VERDICT=yes
    job H1
    expect_event "H1 1 $CORES"
    # Slot 2 locked with no holder: what a status probe looks like for the
    # instant it holds the lock. Slot 3 opens only beside two real builds.
    mkfifo "$T/release.P"
    lockf -k "$SLOTS/slot2" sh -c 'echo "P probe" > "$1/events"; read -r x < "$1/release.P"' probe "$T" &
    P=$!
    PIDS="$PIDS $P"
    expect_event "P probe"
    job J
    expect_wait "number 1 in line"
    release P
    expect_event "J 2 $((CORES / 2))"
    release J
    release H1
}

test_the_third_slot_stays_shut_on_a_no() {
    hold_two
    export LEXICON_MACHINE_VERDICT=no
    job J
    expect_wait "number 1 in line"
    # J asks the verdict on every try; after three more, slot 3 is still free.
    # timing-ok: the read limit only bounds a hang.
    for n in 1 2 3 4; do
        read -r -t 30 got <&5 || fail "J stopped trying for slot 3"
    done
    held 3 && fail "slot 3 was taken on a no"
    kill -0 "$J" || fail "J stopped waiting"
    release H1
    expect_event "J 1 $((CORES / 2))"
    release J
    release H2
}

test_quiet_holds_every_slot_and_the_line_waits_behind_it() {
    export LEXICON_MACHINE_VERDICT=yes
    job Q --quiet
    expect_event "Q quiet $CORES"
    held 1 && held 2 && held 3 || fail "quiet does not hold all three slots"
    job J
    expect_wait "number 1 in line"
    release Q
    expect_event "J 1 $CORES"
    release J
    held 1 || held 2 || held 3 && fail "a slot is still held"
    true
}

test_quiet_waits_in_line_like_any_job() {
    export LEXICON_MACHINE_VERDICT=no
    hold_two
    job Q --quiet
    expect_wait "number 1 in line"
    job J
    expect_wait "number 2 in line"
    release H1
    release H2
    expect_event "Q quiet $CORES"
    release Q
    expect_event "J 1 $CORES"
    release J
}

test_an_entry_whose_pid_was_reused_drops_out() {
    export LEXICON_MACHINE_VERDICT=no
    hold_two
    # A waiter killed earlier in this boot left this entry; its pid now names
    # another process (H1's).
    mkdir -p "$SLOTS/queue"
    echo "Thu Jan  1 00:00:00 1970" > "$SLOTS/queue/0000000000.$H1"
    job A
    expect_wait "number 1 in line"
    release H1
    expect_event "A 1 $((CORES / 2))"
    release A
    release H2
}

test_a_waiting_quiet_run_holds_no_slot() {
    export LEXICON_MACHINE_VERDICT=no
    hold_two
    job Q --quiet
    expect_wait "number 1 in line"
    # Only the waiter dies, as when a session's own process is killed: nothing
    # it started may keep a slot or run its command later. Killed once it has a
    # child: a lockf trying the slots, or the wait between tries.
    n=0
    until pgrep -P "$Q" > /dev/null; do
        n=$((n + 1))
        [ "$n" -lt 5000 ] || fail "Q never tried the slots"
    done
    kill -KILL "$Q"
    wait "$Q" 2> /dev/null || true
    release H1
    job J
    expect_event "J 1 $((CORES / 2))"
    release J
    release H2
}

test_a_slot_holder_runs_nested_jobs_in_its_own_slot() {
    export LEXICON_MACHINE_VERDICT=no
    hold_two
    out=$(HEAVY_SLOT=2 sh -c '. scripts/lib/heavy.sh; heavy scripts/no-such-script.sh; echo "nested in $HEAVY_SLOT"')
    [ "$out" = "nested in 2" ] || fail "sourced: got '$out'"
    out=$(HEAVY_SLOT=2 scripts/lib/heavy.sh sh -c 'echo "run in $HEAVY_SLOT"')
    [ "$out" = "run in 2" ] || fail "run: got '$out'"
    [ -z "$(ls "$SLOTS/queue" 2> /dev/null)" ] || fail "a nested job queued"
    release H1
    release H2
}

test_status_counts_slots_and_the_line() {
    export LEXICON_MACHINE_VERDICT=no
    hold_two
    job A
    expect_wait "number 1 in line"
    out=$(scripts/lib/heavy.sh status)
    case "$out" in *"build slots 2 of 3 in use | queue: 1 waiting"*) ;; *) fail "status: $out" ;; esac
    release H1
    expect_event "A 1 $((CORES / 2))"
    release A
    release H2
}

for t in $(sed -n 's/^\(test_[a-z0-9_]*\)().*/\1/p' "$0"); do
    case "$t" in *"${1:-}"*) ;; *) continue ;; esac
    total=$((total + 1))
    if (setup && "$t"); then
        echo "ok   $t"
    else
        failed=$((failed + 1))
        echo "FAIL $t"
    fi
done
[ "$total" -gt 0 ] || { echo "test-heavy: no test matched '${1:-}'" >&2; exit 1; }
echo "test-heavy: $((total - failed)) of $total passed"
[ "$failed" -eq 0 ]
