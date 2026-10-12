#!/bin/sh
# live-lane: the live-app lane and the Live checks session's queue. Only the
# lane's holder drives Lexicon Dev (fn, the mic, paste, Accessibility), so two
# sessions never drive it at once: scripts/dev-run.sh and scripts/harness.sh
# refuse anyone else. Builders stay headless and post a typed request
# (scripts/live-request.sh).
#
#   scripts/live-lane.sh take <name>        take the lane for this session
#   scripts/live-lane.sh release            give it back (only its holder can); restores parked data
#   scripts/live-lane.sh status             who holds it, and whether a sitting is open
#   scripts/live-lane.sh check              succeed only if this session holds it
#
#   scripts/live-lane.sh queue              open requests in arrival order, and due timers
#   scripts/live-lane.sh idle [seconds]     succeed once Jake hasn't typed or moved the mouse for that long (default 30)
#   scripts/live-lane.sh timer <seconds> <label>   note a long wait instead of sitting on the lane
#   scripts/live-lane.sh timers             each timer, due or not
#   scripts/live-lane.sh preflight <issue>  refuse what that issue's request can't pass; print the open command
#
#   scripts/live-lane.sh sitting render     Jake's queued items as one numbered checklist
#   scripts/live-lane.sh sitting start      on Jake's go: open the sitting (writes the marker)
#   scripts/live-lane.sh sitting ack <step> pass|fail|skip [note]
#   scripts/live-lane.sh sitting end        close it and print every step's ack
#
#   scripts/live-lane.sh daily quit|reopen  quit Jake's daily Lexicon from its menu around a sitting, then reopen it
#   scripts/live-lane.sh park | restore     move Lexicon Dev's data aside for a fresh start, and back
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
. scripts/lib/fn-listeners.sh
flavor dev

SUPPORT="$HOME/Library/Application Support"
DATA="$SUPPORT/$NAME"
LOCK="$DATA/live-lane.lock"
# The guard (.claude/hooks/guard.mjs) allows a tccutil reset of Lexicon Dev
# only while this exists: each reset costs Jake an Allow click in a sitting.
MARKER="$DATA/live-sitting.open"
STATE="$DATA/live-lane"
PARKED="$SUPPORT/$NAME parked"
DAILY_ID=dev.jparker.lexicon

die() { echo "live-lane: $*" >&2; exit 1; }

# In UTC, so a clock change or a new time zone never makes a live holder look stale.
started() { TZ=UTC ps -o lstart= -p "$1" 2>/dev/null || true; }
parent() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }

# Sets holder and pid from a live lock. Fails, clearing it if stale, otherwise.
read_lock() {
    held=
    [ -f "$LOCK" ] || return 1
    lock=$(cat "$LOCK")
    holder=$(printf '%s\n' "$lock" | sed -n 's/^name=//p')
    pid=$(printf '%s\n' "$lock" | sed -n 's/^pid=//p')
    since=$(printf '%s\n' "$lock" | sed -n 's/^started=//p')
    if [ -n "$pid" ] && [ -n "$since" ] && [ "$(started "$pid")" = "$since" ]; then held=1; return 0; fi
    # Moved aside, not deleted, so a lock someone took since the read goes back.
    mv -f "$LOCK" "$LOCK.stale.$$" 2>/dev/null || true
    if [ -f "$LOCK.stale.$$" ] && [ "$(cat "$LOCK.stale.$$")" != "$lock" ]; then ln "$LOCK.stale.$$" "$LOCK" 2>/dev/null || true; fi
    rm -f "$LOCK.stale.$$"
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

require_lane() { read_lock && holds || refuse; }

# --- the queue ---------------------------------------------------------------

# Every open issue with its body and comments, fetched once per command, in
# the main shell (a fetch inside $(...) would not outlive its subshell).
ISSUES=
fetch_issues() {
    ISSUES=$(mktemp -t live-lane)
    trap 'rm -f "$ISSUES" "$ISSUES".*' EXIT
    gh issue list --state open --limit 500 --json number,body,comments > "$ISSUES"
}
issues() { cat "$ISSUES"; }

# One line per open request, oldest first: created, issue, branch @ sha7, comment
# index. Only each issue's newest request counts (a fix sends a new one), and
# only until a `Live checks: <branch> @ <sha7>` result answers it.
requests() {
    issues | jq -r '
        .[] | .number as $n | .comments as $c
        | [range(0; $c | length) | select($c[.].body | startswith("Live checks request: "))] | last // empty
        | . as $i | ($c[$i].body | split("\n")[0] | ltrimstr("Live checks request: ") | rtrimstr("\r")) as $head
        | select([$c[$i + 1:][] | .body | startswith("Live checks: " + $head)] | any | not)
        | [$c[$i].createdAt, $n, $head, $i] | @tsv' | sort
}

# The comment body of request number $2 on issue $1.
request_body() { issues | jq -r --argjson n "$1" --argjson i "$2" '.[] | select(.number == $n) | .comments[$i].body'; }

# The issue's body and comments, for its out-of-scope lines.
issue_text() { issues | jq -r --argjson n "$1" '.[] | select(.number == $n) | .body, .comments[].body'; }

is_open() { issues | jq -e --argjson n "$1" 'any(.[]; .number == $n)' > /dev/null; }

# The parsed items of one request (scripts/live-request.sh items).
items_of() { request_body "$1" "$2" | scripts/live-request.sh items - || die "#$1's request can't be read: fix the fields named above and post it again"; }

fn_dependent() { printf '%s\n' "$1" | grep -qiE '(^|[^a-z])fn([^a-z]|$)'; }

# Prints why one item can't pass at this head, one line per reason; nothing if it can.
# $1 issue, $2 sha7, $3 the item's tab-separated line.
static_refusals() {
    printf '%s\n' "$3" | {
        IFS='	' read -r n title kind gesture target speak cue observable pass needs minutes
        label="#$1 item $n ($title)"
        printf '%s\n' "$needs" | tr ';' '\n' | while read -r need; do
            case "$need" in
                "" | none) ;;
                \#*)
                    number=${need#\#}
                    if is_open "$number"; then echo "$label needs #$number, which is still open"; fi
                    ;;
                *)
                    printf %s "$need" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
                    git cat-file -e "$2^{commit}" 2>/dev/null || git fetch -q origin 2>/dev/null || true
                    git cat-file -e "$2^{commit}" 2>/dev/null || { echo "$label: $2 is not in this repo; fetch it"; continue; }
                    # A use site is any line naming it other than its declaration or a comment.
                    uses=$(git grep -h -w -e "$need" "$2" -- Sources 2>/dev/null \
                        | grep -vE "(var|let|func|case|struct|class|enum|protocol|typealias|actor)[[:space:]]+$need([^A-Za-z0-9_]|$)" \
                        | grep -vE '^[[:space:]]*//' || true)
                    [ -n "$uses" ] || echo "$label needs $need, but nothing reads $need at this sha ($2)"
                    ;;
            esac
        done
        lower=$(printf %s "$title" | tr 'A-Z' 'a-z')
        issue_text "$1" | tr 'A-Z' 'a-z' | grep 'out of scope' | grep -F -- "$lower" | head -1 | while read -r line; do
            echo "$label: the issue marks it out of scope: \"$line\""
        done
    }
}

# Prerequisite steps from a needs field: anything not none, #N or a Swift name.
prerequisites() {
    printf '%s\n' "$1" | tr ';' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
        | grep -vE '^(none|#[0-9]+|[A-Za-z_][A-Za-z0-9_]*)?$' || true
}

INSTALLED="$HOME/Applications/$NAME.app"

preflight() {
    issue=${1#\#}
    line=$(requests | awk -F'\t' -v n="$issue" '$2 == n') || true
    [ -n "$line" ] || die "#$issue has no open Live checks request"
    head=$(printf '%s\n' "$line" | cut -f3)
    sha=${head##* @ }
    items=$(items_of "$issue" "$(printf '%s\n' "$line" | cut -f4)")
    reasons=$(printf '%s\n' "$items" | while IFS= read -r item; do static_refusals "$issue" "$sha" "$item"; done)
    hooks=
    fn=
    while IFS='	' read -r n title kind gesture rest; do
        if printf '%s\n' "$gesture" | grep -qi hook; then hooks="$hooks $n"; fi
        if fn_dependent "$gesture"; then fn="$fn $n"; fi
    done <<EOF
$items
EOF
    if [ ! -x "$INSTALLED/Contents/MacOS/Lexicon" ]; then
        reasons="$reasons
$NAME is not installed: run scripts/dev-run.sh at $sha first"
    else
        commit=$(plutil -extract LexiconCommit raw "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)
        case "$commit" in
            "$sha"*) ;;
            *) reasons="$reasons
the installed $NAME is at ${commit:-an unknown commit}, not $sha: run scripts/dev-run.sh at $sha" ;;
        esac
        # Test hooks exist only in debug builds (scripts/bundle.sh).
        if [ -n "$hooks" ] && ! grep -q -a TestHook "$INSTALLED/Contents/MacOS/Lexicon"; then
            reasons="$reasons
items$hooks use test hooks, but the installed $NAME is a release build, which has none: run scripts/dev-run.sh -- --test-hooks"
        fi
    fi
    if [ -n "$fn" ]; then
        listeners=$(require_no_fn_listeners 2>&1) || reasons="$reasons
items$fn use fn: $listeners"
    fi
    reasons=$(printf '%s\n' "$reasons" | sed '/^$/d')
    echo "preflight: #$issue $head, $(printf '%s\n' "$items" | wc -l | tr -d ' ') items; $(fn_listeners_line)"
    if [ -n "$reasons" ]; then
        printf '%s\n' "$reasons" | sed 's/^/refused: /' >&2
        exit 1
    fi
    if [ -n "$hooks" ]; then
        echo "open command: open \"$INSTALLED\" --args --test-hooks"
    else
        echo "open command: open \"$INSTALLED\""
    fi
}

# --- sittings ------------------------------------------------------------------

# Jake's default sitting slots, 11 AM and 6 PM Pacific; he moves them freely.
next_slot() {
    hour=$(TZ=America/Los_Angeles date +%H)
    if [ "$hour" -lt 11 ]; then echo "today 11 AM Pacific"
    elif [ "$hour" -lt 18 ]; then echo "today 6 PM Pacific"
    else echo "tomorrow 11 AM Pacific"
    fi
}

# Writes $STATE/sitting.tsv (step, issue, head, item, title, fn) and prints the checklist.
sitting_render() {
    mkdir -p "$STATE"
    steps=$(mktemp -t live-sitting)
    out=$(mktemp -t live-sitting)
    skipped=
    requests > "$ISSUES.requests"
    while IFS='	' read -r created issue head index; do
        sha=${head##* @ }
        items=$(items_of "$issue" "$index")
        printf '%s\n' "$items" | while IFS= read -r item; do
            kind=$(printf '%s\n' "$item" | cut -f3)
            [ "$kind" = jake ] || continue
            why=$(static_refusals "$issue" "$sha" "$item")
            if [ -n "$why" ]; then printf 'skip\t%s\n' "$why"; else printf 'item\t%s\t%s\t%s\n' "$issue" "$head" "$item"; fi
        done
    done < "$ISSUES.requests" > "$steps"
    if ! grep -q '^item' "$steps"; then
        rm -f "$STATE/sitting.tsv" "$STATE/sitting.txt"
        echo "No Jake items are queued, so no sitting."
        sed -n 's/^skip	/not in a sitting: /p' "$steps"
        rm -f "$steps" "$out"
        return 0
    fi
    # Prerequisites first, each its own step, once each; then the items in arrival order.
    awk -F'\t' '$1 == "item" { print $13 }' "$steps" | while IFS= read -r needs; do prerequisites "$needs"; done \
        | awk '!seen[$0]++' > "$out.pre"
    : > "$STATE/sitting.tsv"
    {
        n=0
        minutes=0
        while IFS= read -r pre; do
            n=$((n + 1)); minutes=$((minutes + 1))
            printf '%d\t-\t-\t-\t%s\tno\n' "$n" "$pre" >> "$STATE/sitting.tsv"
            echo "$n. First: $pre. (1 min)"
        done < "$out.pre"
        awk -F'\t' '$1 == "item"' "$steps" > "$out.items"
        while IFS='	' read -r _ issue head item title kind gesture target speak cue observable pass needs mins; do
            n=$((n + 1)); minutes=$((minutes + mins))
            if fn_dependent "$gesture"; then fn=yes; else fn=no; fi
            printf '%d\t%s\t%s\t%s\t%s\t%s\n' "$n" "$issue" "$head" "$item" "$title" "$fn" >> "$STATE/sitting.tsv"
            if [ "$speak" = yes ]; then say="Speak."; else say="Don't speak."; fi
            echo "$n. $title (#$issue): $gesture, in $target. $say Cue: $cue. ($mins min)"
        done < "$out.items"
        echo "$n steps, about $minutes minutes."
    } > "$out.list"
    {
        echo "Sitting: $(tail -1 "$out.list") Next default slot: $(next_slot) (move it freely)."
        echo "Live checks quits your daily Lexicon from its menu first and reopens it after."
        echo
        sed '$d' "$out.list"
        echo
        echo 'Ack each step by its number: "3 pass", or "4 fail: what you saw".'
        if grep -q '^skip' "$steps"; then
            echo
            sed -n 's/^skip	/Not in this sitting: /p' "$steps"
        fi
    } > "$STATE/sitting.txt"
    cat "$STATE/sitting.txt"
    rm -f "$steps" "$out" "$out".*
}

sitting() {
    case "${1:-}" in
        render) fetch_issues; sitting_render ;;
        start)
            require_lane
            [ ! -e "$MARKER" ] || die "a sitting is already open (sitting end closes it)"
            [ -s "$STATE/sitting.tsv" ] || die "no rendered sitting with Jake's steps: run sitting render, and start one only when it has steps"
            if awk -F'\t' '$6 == "yes"' "$STATE/sitting.tsv" | grep -q .; then
                require_no_fn_listeners || die "this sitting has fn steps; quit the listeners above (daily quit for the daily Lexicon), then start again"
            fi
            printf 'started=%s\nholder=%s\n' "$(TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ')" "$holder" > "$MARKER"
            : > "$STATE/sitting.acks"
            echo "live-lane: sitting open ($(wc -l < "$STATE/sitting.tsv" | tr -d ' ') steps). $(fn_listeners_line)"
            ;;
        ack)
            require_lane
            [ -e "$MARKER" ] || die "no sitting is open"
            step=${2:-}
            verdict=${3:-}
            case "$verdict" in pass | fail | skip) ;; *) die "usage: sitting ack <step> pass|fail|skip [note]" ;; esac
            title=$(awk -F'\t' -v s="$step" '$1 == s { print $5 }' "$STATE/sitting.tsv")
            [ -n "$title" ] || die "the sitting has no step $step"
            shift 3
            printf '%s\t%s\t%s\n' "$step" "$verdict" "$*" >> "$STATE/sitting.acks"
            echo "step $step ($title): $verdict${*:+: $*}"
            ;;
        end)
            require_lane
            [ -e "$MARKER" ] || die "no sitting is open"
            while IFS='	' read -r step issue head item title fn; do
                ack=$(awk -F'\t' -v s="$step" '$1 == s { a = $2 ($3 != "" ? ": " $3 : "") } END { print a }' "$STATE/sitting.acks")
                where=; [ "$issue" = - ] || where=" (#$issue $head item $item)"
                echo "$step. $title$where: ${ack:-no ack}"
            done < "$STATE/sitting.tsv"
            rm -f "$MARKER" "$STATE/sitting.tsv" "$STATE/sitting.txt" "$STATE/sitting.acks"
            echo "live-lane: sitting closed"
            ;;
        *) echo "usage: live-lane.sh sitting render | start | ack <step> pass|fail|skip [note] | end" >&2; exit 64 ;;
    esac
}

# --- Jake's daily copy -----------------------------------------------------------

daily_pid() { lsappinfo info -only pid "$DAILY_ID" | sed -n 's/^"pid"=\([0-9][0-9]*\)$/\1/p'; }

# A Dictation is in progress when the daily app's newest fn gesture in the last
# 21 minutes (the 20-minute cap plus landing) is one that starts or keeps one.
dictating() {
    last=$(/usr/bin/log show --last 21m --style compact --predicate \
        "subsystem == \"$DAILY_ID\" && eventMessage BEGINSWITH \"fn gesture: \"" 2>/dev/null \
        | sed -n 's/.*fn gesture: //p' | tail -1)
    case "$last" in began* | confirmed*) return 0 ;; *) return 1 ;; esac
}

daily() {
    require_lane
    app="$HOME/Applications/Lexicon.app"
    case "${1:-}" in
        quit)
            pid=$(daily_pid)
            [ -n "$pid" ] || { echo "live-lane: the daily Lexicon is not running"; return 0; }
            ! dictating || die "the daily Lexicon has a Dictation in progress; wait for it to land"
            # From its own menu, the same Quit Jake clicks: never a kill.
            osascript -e "tell application \"System Events\" to tell (first application process whose bundle identifier is \"$DAILY_ID\")" \
                -e 'click menu bar item 1 of menu bar 2' \
                -e 'click menu item "Quit Lexicon" of menu 1 of menu bar item 1 of menu bar 2' \
                -e 'end tell' > /dev/null
            ticks=0
            while kill -0 "$pid" 2>/dev/null; do
                sleep 0.2
                ticks=$((ticks + 1))
                [ "$ticks" -lt 150 ] || die "the daily Lexicon is still running 30 s after Quit"
            done
            echo "live-lane: quit the daily Lexicon (pid $pid); reopen it with: scripts/live-lane.sh daily reopen"
            ;;
        reopen)
            [ -z "$(daily_pid)" ] || { echo "live-lane: the daily Lexicon is already running"; return 0; }
            open "$app"
            echo "live-lane: reopened $app"
            ;;
        *) echo "usage: live-lane.sh daily quit|reopen" >&2; exit 64 ;;
    esac
}

# --- Lexicon Dev's data ------------------------------------------------------------

dev_running() { ps -axo pid=,comm= | grep -qF "$INSTALLED/Contents/MacOS/"; }

# The lane's own files and the models link stay put: the link points at the
# daily copy's 614 MB model, and losing it means downloading it again.
kept() { case "$1" in models | live-*) return 0 ;; *) return 1 ;; esac; }

park() {
    require_lane
    ! dev_running || die "$NAME is running; quit it before moving its data"
    [ ! -e "$PARKED" ] || die "$PARKED exists already; restore it first"
    mkdir -p "$PARKED"
    printf 'parked-by=live-lane.sh\nfrom=%s\n' "$DATA" > "$PARKED/manifest"
    for path in "$DATA"/* "$DATA"/.[!.]*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        entry=${path##*/}
        kept "$entry" && continue
        mv "$path" "$PARKED/$entry"
        printf 'entry=%s\n' "$entry" >> "$PARKED/manifest"
    done
    echo "live-lane: parked $(grep -c '^entry=' "$PARKED/manifest") entries of $NAME's data; restore puts them back"
}

restore() {
    [ -e "$PARKED" ] || { echo "live-lane: nothing is parked"; return 0; }
    # Only a folder park made, for this data folder: never move someone else's files in.
    [ "$(sed -n 1p "$PARKED/manifest" 2>/dev/null)" = parked-by=live-lane.sh ] \
        && [ "$(sed -n 2p "$PARKED/manifest")" = "from=$DATA" ] \
        || die "$PARKED was not made by live-lane.sh park; not restoring from it"
    ! dev_running || die "$NAME is running; quit it before moving its data"
    leftovers=
    for path in "$DATA"/* "$DATA"/.[!.]*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        entry=${path##*/}
        kept "$entry" && continue
        [ -n "$leftovers" ] || leftovers=$(mktemp -d "${TMPDIR:-/tmp}/lexicon-dev-unparked.XXXXXX")
        mv "$path" "$leftovers/$entry"
    done
    sed -n 's/^entry=//p' "$PARKED/manifest" | while IFS= read -r entry; do
        mv "$PARKED/$entry" "$DATA/$entry"
    done
    rm "$PARKED/manifest"
    rmdir "$PARKED" || die "$PARKED still has files the manifest doesn't name; left in place"
    echo "live-lane: restored $NAME's data${leftovers:+; what the parked run wrote is in $leftovers}"
}

# --- timers and idle -------------------------------------------------------------------

timers() {
    now=$(date +%s)
    for file in "$STATE"/timer.*; do
        [ -f "$file" ] || continue
        due=$(cat "$file")
        label=${file##*/timer.}
        if [ "$due" -le "$now" ]; then
            echo "timer $label: due"
            rm -f "$file"
        else
            echo "timer $label: due in $((due - now)) s"
        fi
    done
}

# Seconds since the last key press or mouse move (IOHIDSystem's HIDIdleTime, in ns).
idle_seconds() { ioreg -c IOHIDSystem -d 4 | awk '/"HIDIdleTime"/ { print int($NF / 1000000000); exit }'; }

case "${1:-}" in
    take)
        [ -n "${2:-}" ] || { echo "usage: live-lane.sh take <name>" >&2; exit 64; }
        name=$(printf %s "$2" | tr -d '\n')
        if read_lock && ! holds; then refuse; fi
        me=$(session)
        mkdir -p "$(dirname "$LOCK")"
        printf 'name=%s\npid=%s\nstarted=%s\n' "$name" "$me" "$(started "$me")" > "$LOCK.$$"
        # A link fails if the lock appeared since the read, so a race never steals it.
        if [ -n "$held" ]; then mv -f "$LOCK.$$" "$LOCK"
        elif ! ln "$LOCK.$$" "$LOCK" 2>/dev/null; then rm -f "$LOCK.$$"; read_lock || true; refuse
        fi
        rm -f "$LOCK.$$"
        echo "live-lane: $name holds the live-app lane (pid $me)"
        # A holder that ended mid-park left Dev's data aside: put it back.
        [ ! -e "$PARKED" ] || restore
        ;;
    release)
        if ! read_lock; then echo "live-lane: nobody holds the live-app lane"; exit 0; fi
        holds || refuse
        restore
        rm -f "$LOCK"
        echo "live-lane: $holder released the live-app lane"
        ;;
    status)
        if read_lock; then echo "live-lane: held by $holder (pid $pid)"; else echo "live-lane: free"; fi
        [ ! -e "$MARKER" ] || echo "live-lane: a sitting is open ($(sed -n 's/^started=//p' "$MARKER"))"
        [ ! -e "$PARKED" ] || echo "live-lane: $NAME's data is parked"
        echo "live-lane: $(fn_listeners_line)"
        ;;
    check)
        require_lane
        ;;
    queue)
        fetch_issues
        timers
        requests | awk -F'\t' '{ printf "%d. #%s %s (%s)\n", NR, $2, $3, $1 }'
        ;;
    idle)
        want=${2:-30}
        have=$(idle_seconds)
        [ -n "$have" ] || die "ioreg gave no HIDIdleTime"
        [ "$have" -ge "$want" ] || { echo "live-lane: Jake is at the keyboard (idle $have s, want $want s)" >&2; exit 1; }
        echo "live-lane: idle $have s"
        ;;
    timer)
        require_lane
        [ $# -eq 3 ] && [ "$2" -ge 0 ] 2>/dev/null || { echo "usage: live-lane.sh timer <seconds> <label>" >&2; exit 64; }
        mkdir -p "$STATE"
        echo $(($(date +%s) + $2)) > "$STATE/timer.$(printf %s "$3" | tr -c 'A-Za-z0-9._-' -)"
        echo "live-lane: timer $3 due in $2 s; run other items meanwhile (queue shows it when due)"
        ;;
    timers) timers ;;
    preflight)
        [ $# -eq 2 ] || { echo "usage: live-lane.sh preflight <issue>" >&2; exit 64; }
        fetch_issues
        preflight "$2"
        ;;
    sitting) shift; sitting "$@" ;;
    daily) daily "${2:-}" ;;
    park) park ;;
    restore) require_lane; restore ;;
    *)
        echo "usage: live-lane.sh take <name> | release | status | check | queue | idle [s] | timer <s> <label> | timers | preflight <issue> | sitting ... | daily quit|reopen | park | restore" >&2
        exit 64
        ;;
esac
