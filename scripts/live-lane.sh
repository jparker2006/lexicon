#!/bin/sh
# live-lane: the live-app lane lock. scripts/dev-run.sh and scripts/harness.sh
# run only for the session that holds it, so two sessions can never drive
# Lexicon Dev (fn, the mic, paste, Accessibility) at once. The Live checks
# session holds it; builders stay headless and send it a checklist.
#
#   scripts/live-lane.sh take <name>   take the lane for this session
#   scripts/live-lane.sh release       give it back (only its holder can)
#   scripts/live-lane.sh status        who holds it
#   scripts/live-lane.sh check         succeed only if this session holds it
#
# The lock names the holder's session process: the nearest Claude Code process
# above the caller, else the caller's shell. Not the shell alone, because each
# agent Bash call is a fresh shell that ends with the call. A command holds the
# lane when that process is one of its ancestors. The process's start time is
# kept too, so a lock whose process died, or whose PID now belongs to another
# process, is stale and cleared.
set -eu
cd "$(dirname "$0")/.."
. scripts/lib/flavor.sh
flavor dev

LOCK="$HOME/Library/Application Support/$NAME/live-lane.lock"

started() { ps -o lstart= -p "$1" 2>/dev/null || true; }
parent() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

# Sets holder and pid from a live lock. Fails, clearing it if stale, otherwise.
read_lock() {
    [ -f "$LOCK" ] || return 1
    holder=$(sed -n 's/^name=//p' "$LOCK")
    pid=$(sed -n 's/^pid=//p' "$LOCK")
    since=$(sed -n 's/^started=//p' "$LOCK")
    if [ -n "$pid" ] && [ -n "$since" ] && [ "$(started "$pid")" = "$since" ]; then return 0; fi
    rm -f "$LOCK"
    echo "live-lane: cleared a stale lock from $holder (pid $pid, no longer running)" >&2
    holder=
    return 1
}

holds() {
    p=$$
    while [ -n "$p" ] && [ "$p" -gt 1 ]; do
        [ "$p" != "$pid" ] || return 0
        p=$(parent "$p")
    done
    return 1
}

session() {
    p=$PPID
    while [ -n "$p" ] && [ "$p" -gt 1 ]; do
        case "$(ps -o comm= -p "$p")" in claude | */claude) echo "$p"; return ;; esac
        p=$(parent "$p")
    done
    echo "$PPID"
}

refuse() {
    if [ -n "${holder:-}" ]; then
        echo "live-lane: the live-app lane is held by $holder (pid $pid). Only the holder drives Lexicon Dev: ask the Live checks session." >&2
    else
        echo "live-lane: nobody holds the live-app lane. Builders don't drive Lexicon Dev: ask the Live checks session." >&2
    fi
    exit 1
}

case "${1:-}" in
    take)
        name=$(printf %s "${2:?usage: live-lane.sh take <name>}" | tr -d '\n')
        if read_lock && ! holds; then refuse; fi
        me=$(session)
        mkdir -p "$(dirname "$LOCK")"
        printf 'name=%s\npid=%s\nstarted=%s\n' "$name" "$me" "$(started "$me")" > "$LOCK.$$"
        # A link fails if the lock appeared since the read, so a race never steals it.
        if [ -n "${holder:-}" ]; then mv -f "$LOCK.$$" "$LOCK"
        elif ! ln "$LOCK.$$" "$LOCK" 2>/dev/null; then rm -f "$LOCK.$$"; read_lock || true; refuse
        fi
        rm -f "$LOCK.$$"
        echo "live-lane: $name holds the live-app lane (pid $me)"
        ;;
    release)
        if ! read_lock; then echo "live-lane: nobody holds the live-app lane"; exit 0; fi
        holds || refuse
        rm -f "$LOCK"
        echo "live-lane: $holder released the live-app lane"
        ;;
    status)
        if read_lock; then echo "live-lane: held by $holder (pid $pid)"; else echo "live-lane: free"; fi
        ;;
    check)
        if read_lock && holds; then exit 0; fi
        refuse
        ;;
    *)
        echo "usage: live-lane.sh take <name> | release | status | check" >&2
        exit 64
        ;;
esac
