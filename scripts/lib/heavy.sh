# Build slots: at most two heavy jobs (swift build, swift test, a bundle, an
# eval run) at once on this Mac, across every worktree. Load follows how many
# heavy jobs overlap, not how many sessions run, and a third build only slows
# the other two and flakes their timing tests.
#
# A script that does heavy work takes a slot first, from the repo root:
#
#     . scripts/lib/heavy.sh
#     heavy scripts/check.sh "$@"     re-runs the script holding a slot
#
# Or run it:
#
#     scripts/lib/heavy.sh <command> [args]           the command in a slot
#     scripts/lib/heavy.sh --quiet <command> [args]   in both slots: a quiet Mac
#                                                     for a timing run
#     scripts/lib/heavy.sh status                     one line per slot
#
# A job that waits says who holds the slots. The slots are lockf(1) locks, so a
# holder that dies frees its slot at once. They live in the git common dir, which
# every worktree of the repo shares: <common dir>/heavy/slot-1 and slot-2, and
# each holder's line in slot-N.holder. A job that holds a slot (HEAVY_SLOT is
# set) runs the scripts it calls in that same slot. While the other slot is held,
# a job builds with half the cores (HEAVY_JOBS, which scripts/lib/swift-flags.sh
# passes as --jobs), so two builds share the Mac instead of fighting for it.

HEAVY_DIR="$(git -C "$(dirname "$0")" rev-parse --path-format=absolute --git-common-dir)/heavy"
HEAVY_LIB="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/scripts/lib/heavy.sh"

# Succeeds while slot $1 is held. lockf exits 75 when it can't take the lock.
heavy_held() {
    heavy_probe=0
    lockf -s -k -t 0 "$HEAVY_DIR/slot-$1" true || heavy_probe=$?
    [ "$heavy_probe" -eq 75 ]
}

heavy_holder() {
    cat "$HEAVY_DIR/slot-$1.holder" 2>/dev/null || echo "an unknown job"
}

heavy() {
    [ -z "${HEAVY_SLOT:-}" ] || return 0
    mkdir -p "$HEAVY_DIR"
    # The holder touches the token once it runs, which tells "the slot was
    # taken" (lockf's 75) apart from a command that itself exited 75.
    heavy_token=$(mktemp -t heavy)
    rm -f "$heavy_token"
    heavy_waited=
    while :; do
        for heavy_n in 1 2; do
            heavy_status=0
            lockf -s -k -t 0 "$HEAVY_DIR/slot-$heavy_n" "$HEAVY_LIB" --holding "$heavy_n" "$heavy_token" "$@" || heavy_status=$?
            if [ -e "$heavy_token" ]; then
                rm -f "$heavy_token"
                exit "$heavy_status"
            fi
            if [ "$heavy_status" -ne 75 ]; then
                echo "heavy: could not take a build slot in $HEAVY_DIR (lockf exit $heavy_status)" >&2
                exit 1
            fi
        done
        if [ -z "$heavy_waited" ]; then
            for heavy_n in 1 2; do
                echo "heavy: waiting for a build slot; held by $(heavy_holder "$heavy_n")" >&2
            done
            heavy_waited=1
        fi
        sleep 2
    done
}

# Runs in the slot, under lockf: records the holder, then becomes the command.
heavy_holding() {
    slot=$1 token=$2
    shift 2
    [ "$token" = - ] || : > "$token"
    line="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)") (pid $$) running $* since $(date '+%H:%M:%S')"
    if [ "$slot" = quiet ]; then
        for n in 1 2; do printf '%s\n' "$line" > "$HEAVY_DIR/slot-$n.holder"; done
    else
        printf '%s\n' "$line" > "$HEAVY_DIR/slot-$slot.holder"
        if heavy_held $((3 - slot)); then
            HEAVY_JOBS=$(( $(sysctl -n hw.ncpu) / 2 ))
            export HEAVY_JOBS
        fi
    fi
    HEAVY_SLOT=$slot
    export HEAVY_SLOT
    exec "$@"
}

case "$0" in
*/heavy.sh)
    set -eu
    case "${1:-}" in
    --holding)
        shift
        heavy_holding "$@"
        ;;
    --quiet)
        shift
        [ $# -gt 0 ] || { echo "usage: heavy.sh --quiet <command> [args]" >&2; exit 64; }
        [ -z "${HEAVY_SLOT:-}" ] || exec "$@"
        mkdir -p "$HEAVY_DIR"
        for n in 1 2; do
            if heavy_held "$n"; then echo "heavy: waiting for a build slot; held by $(heavy_holder "$n")" >&2; fi
        done
        # Always slot 1 first, and a one-slot job never waits while holding one,
        # so two takers can never each hold the slot the other waits for.
        exec lockf -s -k "$HEAVY_DIR/slot-1" lockf -s -k "$HEAVY_DIR/slot-2" "$HEAVY_LIB" --holding quiet - "$@"
        ;;
    status)
        mkdir -p "$HEAVY_DIR"
        for n in 1 2; do
            if heavy_held "$n"; then echo "heavy: slot $n held by $(heavy_holder "$n")"; else echo "heavy: slot $n free"; fi
        done
        ;;
    "" | -*)
        echo "usage: heavy.sh [--quiet] <command> [args] | status" >&2
        exit 64
        ;;
    *)
        heavy "$@"
        ;;
    esac
    ;;
esac
