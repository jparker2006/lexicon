# Build slots: heavy jobs (swift build, swift test, a bundle, an eval run) take
# turns in three slots on this Mac, across every worktree, first come first
# served. Load follows how many heavy jobs overlap, not how many sessions run.
# Slots 1 and 2 are always open. Slot 3 opens only while the machine verdict
# (scripts/lib/verdict.sh, the rule scripts/machine.sh prints) says the Mac has
# room, since a third build on a busy Mac only slows the other two and flakes
# their timing tests.
#
# A script that does heavy work takes a slot first, from the repo root:
#
#     . scripts/lib/heavy.sh
#     heavy scripts/check.sh "$@"     re-runs the script holding a slot
#
# Or run it:
#
#     scripts/lib/heavy.sh <command> [args]           the command in a slot
#     scripts/lib/heavy.sh --quiet <command> [args]   in every slot: a quiet Mac
#                                                     for a timing run
#     scripts/lib/heavy.sh status                     the slots and the line
#
# A job that can't take a slot at once joins one line shared by every worktree
# and clone on the Mac, and only the job at its head may take a free slot, so a
# job that polls at the right moment never jumps ahead of one that has waited
# longer. The job says its place in line and who holds the slots, and tries
# again every HEAVY_POLL seconds (2; the tests use less). A quiet run waits in
# the same line, then takes every slot, slot 1 first.
#
# Everything lives beside the live-app lane lock, in
# ~/Library/Application Support/Lexicon Dev/heavy/: slot1 to slot3 (the files
# lockf(1) holds, so a holder that dies frees its slot at once), each holder's
# line in slotN.holder, and the line in queue/, one file per waiter named by
# its number and pid. An entry drops out as soon as that process is gone, even
# when a newer process has its pid, so a crashed session never blocks the line.
# scripts/machine.sh and scripts/status.sh read both through heavy_summary.
#
# A job that holds a slot (HEAVY_SLOT is set) runs the scripts it calls in that
# same slot. A build splits the cores by the slots held when it starts
# (HEAVY_JOBS, which scripts/lib/swift-flags.sh passes as --jobs), so builds
# share the Mac instead of fighting for it.

HEAVY_DIR="$HOME/Library/Application Support/Lexicon Dev/heavy"
HEAVY_LIB="$(git rev-parse --show-toplevel)/scripts/lib/heavy.sh"
. "${HEAVY_LIB%/heavy.sh}/verdict.sh"

# Succeeds while slot $1 is held. lockf exits 75 when it can't take the lock;
# -k keeps the file (without it lockf deletes the file it locked) and -n never
# creates a missing one, which is a free slot.
heavy_held() {
    heavy_probe=0
    lockf -k -s -n -t 0 "$HEAVY_DIR/slot$1" true 2> /dev/null || heavy_probe=$?
    [ "$heavy_probe" -eq 75 ]
}

# Succeeds while slot $1 holds a job: its holder line names a live process.
# A probe (heavy_held, here or in scripts/machine.sh) holds the lock for an
# instant and names none, so it never counts as a build beside which slot 3 opens.
heavy_building() {
    heavy_pid=$(sed -n 's/.* (pid \([0-9]*\)) running .*/\1/p' "$HEAVY_DIR/slot$1.holder" 2> /dev/null)
    [ -n "$heavy_pid" ] && kill -0 "$heavy_pid" 2> /dev/null
}

heavy_holder() {
    cat "$HEAVY_DIR/slot$1.holder" 2>/dev/null || echo "an unknown job"
}

# Whether process $1 runs and, when $2 (seconds since 1970) is given, started
# no later than that, since a pid is reused once its process is gone: 0 yes,
# 1 no, 2 unknown (ps failed for a moment). Both times are the kernel's own,
# read from the process and the file, never from the clock, so a stall between
# readings changes nothing; the start is printed and read back in UTC, which
# has no hour that repeats when the clocks go back. A dead process its parent
# has not yet reaped (a zombie, which kill -0 still finds) is gone.
heavy_alive() {
    heavy_by=${2:-}
    kill -0 "$1" 2> /dev/null || return 1
    heavy_ps=$(TZ=UTC LC_ALL=C ps -o stat=,lstart= -p "$1" 2> /dev/null) || return 2
    [ -n "$heavy_ps" ] || return 2
    # Split by a command substitution, which zsh splits too.
    set -- $(printf '%s\n' "$heavy_ps")
    case "$1" in Z*) return 1 ;; esac
    [ -n "$heavy_by" ] || return 0
    shift
    heavy_since=$(TZ=UTC LC_ALL=C date -j -f '%a %b %e %T %Y' "$*" +%s 2> /dev/null) || return 2
    [ "$heavy_since" -le "$heavy_by" ]
}

# The line's live entries, first come first. With "prune", deletes the rest.
# An entry is its waiter's while that pid's process runs and started before the
# entry was written. One heavy_alive can't judge stays: a blip must not cost a
# job its place. An entry the job ahead deletes as it takes a slot just drops
# from the list.
heavy_queue() {
    for heavy_q in "$HEAVY_DIR"/queue/*; do
        [ -f "$heavy_q" ] || continue
        heavy_q_written=$(stat -f %m "$heavy_q" 2> /dev/null) || {
            [ -e "$heavy_q" ] || continue
            heavy_q_written=
        }
        heavy_q_alive=0
        heavy_alive "${heavy_q##*.}" "$heavy_q_written" || heavy_q_alive=$?
        if [ "$heavy_q_alive" -ne 1 ]; then
            echo "$heavy_q"
        elif [ "${1:-}" = prune ]; then
            rm -f "$heavy_q"
        fi
    done
}

# One line for scripts/machine.sh and scripts/status.sh.
heavy_summary() {
    heavy_used=0
    for heavy_n in 1 2 3; do
        if heavy_held "$heavy_n"; then heavy_used=$((heavy_used + 1)); fi
    done
    echo "build slots $heavy_used of 3 in use | queue: $(heavy_queue | wc -l | tr -d ' ') waiting"
}

# Whether the Mac has room for the third slot now: the machine verdict, with
# page-outs counted since this waiter's last try, so a first try is a no.
heavy_room() {
    heavy_after=$(verdict_pageouts)
    heavy_now=$(date +%s)
    heavy_ok=0
    verdict "$heavy_before" "$heavy_after" $((heavy_now - ${heavy_at:-$heavy_now})) || heavy_ok=1
    heavy_before=$heavy_after heavy_at=$heavy_now
    return "$heavy_ok"
}

# Runs the command holding slot $1 ("quiet": every slot) if lockf can take it
# at once, and then exits with the command's status. Returns when it can't.
heavy_try() {
    heavy_status=0
    if [ "$1" = quiet ]; then
        # Slot 1 first, and nothing held while it waits: a blocking lockf left
        # behind by a killed waiter would keep slot 1 and later run the command
        # for nobody. As the head of the line, nobody behind it takes a slot,
        # so the slots drain to it.
        shift
        lockf -s -k -t 0 "$HEAVY_DIR/slot1" lockf -s -k -t 0 "$HEAVY_DIR/slot2" lockf -s -k -t 0 "$HEAVY_DIR/slot3" \
            "$HEAVY_LIB" --holding quiet "$heavy_entry" "$@" || heavy_status=$?
    else
        heavy_n=$1
        shift
        lockf -s -k -t 0 "$HEAVY_DIR/slot$heavy_n" "$HEAVY_LIB" --holding "$heavy_n" "$heavy_entry" "$@" || heavy_status=$?
    fi
    # The holder deletes the entry once it runs, which tells "the slot was
    # taken" (lockf's 75) apart from a command that itself exited 75.
    if [ ! -e "$heavy_entry" ]; then
        trap - EXIT INT TERM HUP
        exit "$heavy_status"
    fi
    if [ "$heavy_status" -ne 75 ]; then
        echo "heavy: could not take a build slot in $HEAVY_DIR (lockf exit $heavy_status)" >&2
        exit 1
    fi
}

heavy_wait_line() {
    printf 'heavy: waiting for a build slot, number %s in line' "$heavy_place"
    for heavy_n in 1 2 3; do
        if heavy_held "$heavy_n"; then
            printf '; slot %s: %s' "$heavy_n" "$(heavy_holder "$heavy_n")"
        elif [ "$heavy_n" = 3 ] && [ -n "$heavy_noroom" ]; then
            printf '; slot 3: free, but the Mac has no room (%s)' "$verdict_why"
        else
            printf '; slot %s: free' "$heavy_n"
        fi
    done
    echo
}

# Waits in line for a slot ($1 is "quiet" for every slot, or empty), runs the
# rest as the command holding it, and exits with its status.
heavy_run() {
    heavy_mode=$1
    shift
    mkdir -p "$HEAVY_DIR/queue"
    heavy_entry=$(lockf -k "$HEAVY_DIR/queue.lock" "$HEAVY_LIB" --enqueue $$)
    trap 'rm -f "$heavy_entry"' EXIT
    trap 'rm -f "$heavy_entry"; exit 130' INT TERM HUP
    heavy_waited= heavy_before= heavy_at=
    while :; do
        heavy_place=$(heavy_queue prune | grep -n -x -F "$heavy_entry" | cut -d: -f1)
        if [ -z "$heavy_place" ]; then
            echo "heavy: $heavy_entry left the line while it waited" >&2
            exit 1
        fi
        heavy_noroom=
        if [ "$heavy_place" -eq 1 ]; then
            if [ -n "$heavy_mode" ]; then
                heavy_try quiet "$@"
            else
                heavy_try 1 "$@"
                heavy_try 2 "$@"
                if heavy_building 1 && heavy_building 2; then
                    if heavy_room; then heavy_try 3 "$@"; else heavy_noroom=1; fi
                fi
            fi
        fi
        if [ -z "$heavy_waited" ]; then
            heavy_wait_line >&2
            heavy_waited=1
        fi
        sleep "${HEAVY_POLL:-2}"
    done
}

heavy() {
    [ -z "${HEAVY_SLOT:-}" ] || return 0
    heavy_run "" "$@"
}

# Runs in the slot, under lockf: leaves the line, records the holder, then
# becomes the command. A waiter killed while its lockf took the slot has nobody
# to run the command for, so the slot goes back unused; when ps can't say, it
# goes back too, as lockf's "not taken" (75), and a live waiter tries again.
heavy_holding() {
    slot=$1 entry=$2
    shift 2
    heavy_alive "${entry##*.}" || exit 75
    rm -f "$entry"
    line="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)") (pid $$) running $* since $(date '+%H:%M:%S')"
    held=1
    if [ "$slot" = quiet ]; then
        for n in 1 2 3; do printf '%s\n' "$line" > "$HEAVY_DIR/slot$n.holder"; done
    else
        printf '%s\n' "$line" > "$HEAVY_DIR/slot$slot.holder"
        for n in 1 2 3; do
            if [ "$n" != "$slot" ] && heavy_held "$n"; then held=$((held + 1)); fi
        done
    fi
    HEAVY_JOBS=$(( $(sysctl -n hw.ncpu) / held ))
    HEAVY_SLOT=$slot
    export HEAVY_JOBS HEAVY_SLOT
    exec "$@"
}

# Run, not sourced. zsh sets $0 to a sourced file too, so it is asked directly.
case "${ZSH_EVAL_CONTEXT:-}:$0" in
*file:*) ;;
*/heavy.sh)
    set -eu
    case "${1:-}" in
    --holding)
        shift
        heavy_holding "$@"
        ;;
    --enqueue)
        # Under queue.lock: the next number, then the entry.
        n=$(( $(cat "$HEAVY_DIR/queue.next" 2> /dev/null || echo 0) + 1 ))
        echo "$n" > "$HEAVY_DIR/queue.next"
        entry=$(printf '%s/queue/%010d.%s' "$HEAVY_DIR" "$n" "$2")
        : > "$entry"
        echo "$entry"
        ;;
    --quiet)
        shift
        [ $# -gt 0 ] || { echo "usage: heavy.sh --quiet <command> [args]" >&2; exit 64; }
        [ -z "${HEAVY_SLOT:-}" ] || exec "$@"
        heavy_run quiet "$@"
        ;;
    status)
        mkdir -p "$HEAVY_DIR"
        for n in 1 2 3; do
            if heavy_held "$n"; then echo "heavy: slot $n held by $(heavy_holder "$n")"; else echo "heavy: slot $n free"; fi
        done
        echo "heavy: $(heavy_summary)"
        ;;
    "" | -*)
        echo "usage: heavy.sh [--quiet] <command> [args] | status" >&2
        exit 64
        ;;
    *)
        [ -z "${HEAVY_SLOT:-}" ] || exec "$@"
        heavy "$@"
        ;;
    esac
    ;;
esac
