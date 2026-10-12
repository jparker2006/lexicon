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
#   scripts/live-lane.sh idle [seconds]     succeed once Jake hasn't typed or moved the mouse for that long (default 30);
#                                           keys the harness or Dev posts don't count
#   scripts/live-lane.sh timer <seconds> <label>   note a long wait instead of sitting on the lane
#   scripts/live-lane.sh timers             each timer, due or not
#   scripts/live-lane.sh preflight <issue>  refuse what that issue's request can't pass; print the open command
#
#   scripts/live-lane.sh sitting render     Jake's queued items as one numbered checklist
#   scripts/live-lane.sh sitting start      on Jake's go: open the sitting (writes the marker; quits the daily Lexicon for fn steps)
#   scripts/live-lane.sh sitting start --hands-free
#                                           only after Jake types "hands free" here: a sitting with no steps for
#                                           him that quits the daily Lexicon, so hands-off fn items can run
#   scripts/live-lane.sh sitting ack <step> pass|fail|skip [note]
#   scripts/live-lane.sh sitting end        close it, print every step's ack, reopen the daily Lexicon if start quit it
#
#   scripts/live-lane.sh daily quit|reopen  quit Jake's daily Lexicon from its menu in an open sitting, then reopen it
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
# Jake's items, kept from every open request seen (#233): a hands-off result
# answers the request, and the merge closes the issue, before his sitting comes.
JAKE="$STATE/jake-items.tsv"
# The unified log reader; a test sets its own, so it never reads the real Mac's.
LOG=${LIVE_LANE_LOG:-/usr/bin/log}

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

# A sitting is open while its marker names a live session. A session that
# crashed mid-sitting leaves a marker the guard would keep honoring, so the
# next look clears it.
sitting_open() {
    [ -e "$MARKER" ] || return 1
    mpid=$(sed -n 's/^pid=//p' "$MARKER")
    msince=$(sed -n 's/^pid-started=//p' "$MARKER")
    if [ -n "$mpid" ] && [ -n "$msince" ] && [ "$(started "$mpid")" = "$msince" ]; then return 0; fi
    rm -f "$MARKER"
    echo "live-lane: cleared the marker of a sitting whose session ended" >&2
    return 1
}

# --- the queue ---------------------------------------------------------------

# Every open issue with its body and comments, fetched once per command, in
# the main shell (a fetch inside $(...) would not outlive its subshell). The
# repo is public, so only the owner's account counts: anyone else's request,
# result or out-of-scope line is ignored.
ISSUES=
OWNER=
fetch_issues() {
    ISSUES=$(mktemp -t live-lane)
    trap 'rm -f "$ISSUES" "$ISSUES".*' EXIT
    OWNER=$(gh repo view --json owner | jq -r '.owner.login // empty')
    [ -n "$OWNER" ] || die "can't read the repo's owner from gh"
    gh issue list --state open --limit 500 --json number,author,body,comments > "$ISSUES"
}
issues() { cat "$ISSUES"; }

# One line per open request, oldest first: created, issue, branch @ sha7, comment
# index. Only each issue's newest request counts (a fix sends a new one), and
# only until a `Live checks: <branch> @ <sha7>` result answers it, as a plain
# line or a Markdown heading.
requests() {
    issues | jq -r --arg owner "$OWNER" '
        .[] | .number as $n | [.comments[] | select(.author.login == $owner)] as $c
        | [range(0; $c | length) | select($c[.].body | startswith("Live checks request: "))] | last // empty
        | . as $i | ($c[$i].body | split("\n")[0] | ltrimstr("Live checks request: ") | rtrimstr("\r")) as $head
        | select([$c[$i + 1:][] | .body | sub("^[\\s#*]+"; "") | startswith("Live checks: " + $head)] | any | not)
        | [$c[$i].createdAt, $n, $head, $i] | @tsv' | sort
}

# The body of request $2 (an index into the owner's comments) on issue $1.
request_body() { issues | jq -r --arg owner "$OWNER" --argjson n "$1" --argjson i "$2" '.[] | select(.number == $n) | [.comments[] | select(.author.login == $owner)][$i].body'; }

# The owner's issue body and comments, for out-of-scope lines.
issue_text() {
    issues | jq -r --arg owner "$OWNER" --argjson n "$1" \
        '.[] | select(.number == $n) | (select(.author.login == $owner) | .body), (.comments[] | select(.author.login == $owner) | .body)'
}

is_open() { issues | jq -e --argjson n "$1" 'any(.[]; .number == $n)' > /dev/null; }

# The parsed items of one request (scripts/live-request.sh items).
items_of() { request_body "$1" "$2" | scripts/live-request.sh items - || die "#$1's request can't be read: fix the fields named above and post it again"; }

# Prints why one item can't pass at this head, one line per reason; nothing if it can.
# $1 issue, $2 sha7, $3 the item's tab-separated line.
static_refusals() {
    printf '%s\n' "$3" | {
        IFS='	' read -r n title kind gesture target speak fn cue observable pass needs minutes
        label="#$1 item $n ($title)"
        printf '%s\n' "$needs" | tr ';' '\n' | while read -r need; do
            case "$need" in
                "" | none) ;;
                \#*)
                    number=${need#\#}
                    if is_open "$number"; then printf '%s\n' "$label needs #$number, which is still open"; fi
                    ;;
                *)
                    printf %s "$need" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*$' || continue
                    git cat-file -e "$2^{commit}" 2>/dev/null || git fetch -q origin 2>/dev/null || true
                    git cat-file -e "$2^{commit}" 2>/dev/null || { printf '%s\n' "$label: $2 is not in this repo; fetch it"; continue; }
                    # A use site reads it: not its declaration, a comment, an
                    # argument label or parameter (name:), or an assignment to it.
                    uses=$(git grep -h -w -e "$need" "$2" -- Sources 2>/dev/null \
                        | grep -vE "(var|let|func|case|struct|class|enum|protocol|typealias|actor)[[:space:]]+$need([^A-Za-z0-9_]|$)" \
                        | grep -vE "$need[[:space:]]*(:|=[^=])" \
                        | grep -vE '^[[:space:]]*//' || true)
                    [ -n "$uses" ] || printf '%s\n' "$label needs $need, but nothing reads $need at this sha ($2)"
                    ;;
            esac
        done
        # The title as whole words on a line that says "out of scope".
        issue_text "$1" | grep -i 'out of scope' | grep -iwF -- "$title" | head -1 | while IFS= read -r line; do
            printf '%s\n' "$label: the issue marks it out of scope: \"$line\""
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
    while IFS='	' read -r n title kind gesture target speak usesfn rest; do
        if printf '%s\n' "$gesture" | grep -qi hook; then hooks="$hooks $n"; fi
        if [ "$usesfn" = yes ]; then fn="$fn $n"; fi
    done <<EOF
$items
EOF
    if [ ! -x "$INSTALLED/Contents/MacOS/Lexicon" ]; then
        reasons="$reasons
$NAME is not installed: run scripts/dev-run.sh at $sha first"
    else
        commit=$(plutil -extract LexiconCommit raw "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)
        case "$commit" in
            *-dirty) reasons="$reasons
the installed $NAME was built from a dirty tree ($commit): check out $sha clean and run scripts/dev-run.sh" ;;
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

# Writes $ISSUES.jake: the kept Jake items (issue, head, then the item's
# fields), first seen first, with each open request's added. An issue's newer
# request replaces what its older head left. Only the lane's holder saves it
# to $JAKE, on every queue, preflight and render, so an item is kept before the
# hands-off result that answers its request; a builder's look changes nothing.
remember_jake_items() {
    requests > "$ISSUES.remember"
    { [ ! -f "$JAKE" ] || cat "$JAKE"; } > "$ISSUES.kept"
    awk -F'\t' 'FILENAME == ARGV[1] { head[$2] = $3; next } !($1 in head) || head[$1] == $2' "$ISSUES.remember" "$ISSUES.kept" > "$ISSUES.jake"
    while IFS='	' read -r created issue head index; do
        items=$(request_body "$issue" "$index" | scripts/live-request.sh items - 2> /dev/null) || continue
        printf '%s\n' "$items" | awk -F'\t' -v i="$issue" -v h="$head" '$3 == "jake" { print i "\t" h "\t" $0 }'
    done < "$ISSUES.remember" | awk -F'\t' 'FILENAME == ARGV[1] { seen[$1 FS $2 FS $3] = 1; next } !seen[$1 FS $2 FS $3]++' "$ISSUES.jake" - >> "$ISSUES.jake"
    if read_lock 2> /dev/null && holds; then
        mkdir -p "$STATE"
        cp "$ISSUES.jake" "$JAKE.$$"
        mv "$JAKE.$$" "$JAKE"
    fi
}

# Writes $STATE/sitting.tsv (step, issue, head, item, title, fn) and prints the checklist.
sitting_render() {
    # Acks are by step number, so the numbers stay fixed while a sitting is open.
    ! sitting_open || die "a sitting is open; end it before rendering the next one"
    mkdir -p "$STATE"
    remember_jake_items
    steps=$(mktemp -t live-sitting)
    out=$(mktemp -t live-sitting)
    waiting=
    {
        # A request that can't be read stays out of the sitting, named, and the rest go on.
        while IFS='	' read -r created issue head index; do
            if ! items=$(request_body "$issue" "$index" | scripts/live-request.sh items - 2> "$ISSUES.err"); then
                printf 'skip\t#%s %s: the request can'"'"'t be read: %s\n' "$issue" "$head" "$(sed 's/^live-request: //' "$ISSUES.err" | paste -sd ';' - | sed 's/;/; /g')"
                continue
            fi
            # A hands-off fn item has no step for Jake: it waits for the daily Lexicon to quit.
            printf '%s\n' "$items" | awk -F'\t' -v i="$issue" -v h="$head" '$3 == "hands-off" && $7 == "yes" { print "fn\t#" i " " h " item " $1 " (" $2 ")" }'
        done < "$ISSUES.remember"
        while IFS='	' read -r issue head item; do
            why=$(static_refusals "$issue" "${head##* @ }" "$item")
            if [ -n "$why" ]; then printf 'skip\t%s\n' "$why"; else printf 'item\t%s\t%s\t%s\n' "$issue" "$head" "$item"; fi
        done < "$ISSUES.jake"
    } > "$steps"
    if grep -q '^fn' "$steps"; then
        waiting="Waiting for the daily Lexicon to quit: $(sed -n 's/^fn	//p' "$steps" | paste -sd ';' - | sed 's/;/; /g'). They run in the next sitting's hands-off part, or in a hands-free sitting (sitting start --hands-free) once Jake says \"hands free\"."
    fi
    if ! grep -q '^item' "$steps"; then
        rm -f "$STATE/sitting.tsv" "$STATE/sitting.txt"
        echo "No Jake items are queued, so no sitting."
        [ -z "$waiting" ] || echo "$waiting"
        sed -n 's/^skip	/not in a sitting: /p' "$steps"
        rm -f "$steps" "$out"
        return 0
    fi
    # Prerequisites first, each its own step, once each; then the items in arrival order.
    awk -F'\t' '$1 == "item" { print $14 }' "$steps" | while IFS= read -r needs; do prerequisites "$needs"; done \
        | awk '!seen[$0]++' > "$out.pre"
    : > "$STATE/sitting.tsv"
    {
        n=0
        minutes=0
        while IFS= read -r pre; do
            n=$((n + 1)); minutes=$((minutes + 1))
            printf '%d\t-\t-\t-\t%s\tno\n' "$n" "$pre" >> "$STATE/sitting.tsv"
            printf '%s\n' "$n. First: $pre. (1 min)"
        done < "$out.pre"
        awk -F'\t' '$1 == "item"' "$steps" > "$out.items"
        while IFS='	' read -r _ issue head item title kind gesture target speak fn cue observable pass needs mins; do
            n=$((n + 1)); minutes=$((minutes + mins))
            printf '%d\t%s\t%s\t%s\t%s\t%s\n' "$n" "$issue" "$head" "$item" "$title" "$fn" >> "$STATE/sitting.tsv"
            if [ "$speak" = yes ]; then say="Speak."; else say="Don't speak."; fi
            printf '%s\n' "$n. $title (#$issue): $gesture, in $target. $say Cue: $cue. ($mins min)"
        done < "$out.items"
        echo "$n steps, about $minutes minutes."
    } > "$out.list"
    {
        echo "Sitting: $(tail -1 "$out.list") Next default slot: $(next_slot) (move it freely)."
        if awk -F'\t' '$6 == "yes"' "$STATE/sitting.tsv" | grep -q .; then
            echo "It uses fn, so Live checks quits your daily Lexicon from its menu first (daily quit) and reopens it after (daily reopen)."
        fi
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
    [ -z "$waiting" ] || printf '\n%s\n' "$waiting"
    rm -f "$steps" "$out" "$out".*
}

sitting() {
    case "${1:-}" in
        render) fetch_issues; sitting_render ;;
        start)
            require_lane
            ! sitting_open || die "a sitting is already open (sitting end closes it)"
            # Hands-free: Jake typed "hands free" in this session, so the sitting has
            # no steps for him and quits the daily Lexicon for the hands-off fn items.
            case "${2:-}" in
                "") handsfree= ;;
                --hands-free) handsfree=yes ;;
                *) die "usage: live-lane.sh sitting start [--hands-free]" ;;
            esac
            fn=$handsfree
            if [ -z "$handsfree" ]; then
                [ -s "$STATE/sitting.tsv" ] || die "no rendered sitting with Jake's steps: run sitting render, and start one only when it has steps"
                if awk -F'\t' '$6 == "yes"' "$STATE/sitting.tsv" | grep -q .; then fn=yes; fi
            fi
            quit=
            if [ -n "$fn" ]; then
                # Jake's daily Lexicon is quit below, inside the sitting (Q8); any other listener refuses now.
                others=$(fn_listeners | awk -F'|' '$2 != "the daily Lexicon"')
                if [ -n "$others" ]; then
                    printf '%s\n' "$others" | while IFS='|' read -r p what path; do
                        echo "$what is running (pid $p, $path) and answers fn, so Dev's fn results would be wrong. Quit it, then rerun." >&2
                    done
                    die "this sitting uses fn; it didn't open"
                fi
                if fn_listeners | grep -q '|the daily Lexicon|'; then
                    ! dictating || die "the daily Lexicon has a Dictation in progress, so the sitting didn't open; wait for it to land"
                    quit=yes
                fi
            fi
            if [ -n "$handsfree" ]; then
                mkdir -p "$STATE"
                : > "$STATE/sitting.tsv"
                rm -f "$STATE/sitting.txt"
            fi
            printf 'opened=%s\nholder=%s\npid=%s\npid-started=%s\n%s' "$(TZ=UTC date '+%Y-%m-%dT%H:%M:%SZ')" "$holder" "$pid" "$since" "${handsfree:+hands-free=yes
}" > "$MARKER"
            if [ -n "$quit" ]; then
                ( daily quit ) || { rm -f "$MARKER"; die "the sitting didn't open: the daily Lexicon wasn't quit"; }
                require_no_fn_listeners || { rm -f "$MARKER"; die "the sitting didn't open: another app still answers fn"; }
            fi
            : > "$STATE/sitting.acks"
            echo "live-lane: ${handsfree:+hands-free }sitting open ($(wc -l < "$STATE/sitting.tsv" | tr -d ' ') steps). $(fn_listeners_line)"
            ;;
        ack)
            require_lane
            sitting_open || die "no sitting is open"
            step=${2:-}
            verdict=${3:-}
            case "$verdict" in pass | fail | skip) ;; *) die "usage: sitting ack <step> pass|fail|skip [note]" ;; esac
            title=$(awk -F'\t' -v s="$step" '$1 == s { print $5 }' "$STATE/sitting.tsv")
            [ -n "$title" ] || die "the sitting has no step $step"
            shift 3
            printf '%s\t%s\t%s\n' "$step" "$verdict" "$*" >> "$STATE/sitting.acks"
            printf '%s\n' "step $step ($title): $verdict${*:+: $*}"
            ;;
        end)
            require_lane
            sitting_open || die "no sitting is open"
            # A hands-free sitting has no steps, so only a sitting with Jake's can lose them.
            grep -qx 'hands-free=yes' "$MARKER" || [ -s "$STATE/sitting.tsv" ] || die "the open sitting has lost its steps ($STATE/sitting.tsv); its acks are in $STATE/sitting.acks"
            touch "$STATE/sitting.tsv" "$STATE/sitting.acks"
            while IFS='	' read -r step issue head item title fn; do
                ack=$(awk -F'\t' -v s="$step" '$1 == s { a = $2 ($3 != "" ? ": " $3 : "") } END { print a }' "$STATE/sitting.acks")
                where=; [ "$issue" = - ] || where=" (#$issue $head item $item)"
                printf '%s\n' "$step. $title$where: ${ack:-no ack}"
            done < "$STATE/sitting.tsv"
            # A step acked pass or fail leaves Jake's queue; a skip, or no ack, keeps it for the next sitting.
            touch "$JAKE"
            awk -F'\t' 'FILENAME == ARGV[1] { done[$1] = ($2 == "pass" || $2 == "fail"); next }
                FILENAME == ARGV[2] { if (done[$1]) gone[$2 FS $3 FS $4] = 1; next }
                !(($1 FS $2 FS $3) in gone)' "$STATE/sitting.acks" "$STATE/sitting.tsv" "$JAKE" > "$JAKE.$$"
            mv "$JAKE.$$" "$JAKE"
            rm -f "$MARKER" "$STATE/sitting.tsv" "$STATE/sitting.txt" "$STATE/sitting.acks"
            echo "live-lane: sitting closed"
            if [ -e "$STATE/daily-quit" ]; then
                ( daily reopen ) || echo "live-lane: the daily Lexicon didn't reopen; run: scripts/live-lane.sh daily reopen" >&2
            fi
            ;;
        *) echo "usage: live-lane.sh sitting render | start [--hands-free] | ack <step> pass|fail|skip [note] | end" >&2; exit 64 ;;
    esac
}

# --- Jake's daily copy -----------------------------------------------------------

daily_pid() { lsappinfo info -only pid "$DAILY_ID" | sed -n 's/^"pid"=\([0-9][0-9]*\)$/\1/p'; }

# A Dictation is in progress when the daily app's newest Dictation gesture in
# the last 21 minutes (the 20-minute cap plus landing) began or confirmed one.
# KeyInput logs them as "fn gesture: dictationBegan(...)" (subsystem Lexicon, category fn).
dictating() {
    last=$("$LOG" show --last 21m --style compact --predicate \
        "subsystem == \"Lexicon\" && category == \"fn\" && processImagePath CONTAINS \"/Lexicon.app/\" && eventMessage BEGINSWITH \"fn gesture: dictation\"" \
        | sed -n 's/.*fn gesture: //p' | tail -1)
    case "$last" in dictationBegan* | dictationConfirmed*) return 0 ;; *) return 1 ;; esac
}

daily() {
    require_lane
    # Only around a sitting (Q8): quit inside one, reopen only what quit closed.
    case "${1:-}" in
        quit) sitting_open || die "daily quit runs only in an open sitting; sitting start quits it for a sitting with fn steps, and sitting start --hands-free once Jake says \"hands free\"" ;;
        reopen) [ -e "$STATE/daily-quit" ] || die "daily reopen only reopens a daily Lexicon that daily quit closed" ;;
    esac
    # lsappinfo, System Events and open reach the real Mac whatever HOME says,
    # so a run under a test's fake HOME would quit Jake's real app: refuse it.
    real=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{ print $2 }')
    [ -n "$real" ] && [ "$HOME" = "$real" ] || die "HOME ($HOME) is not your login home${real:+ ($real)}; daily quit and reopen act on the real Mac, so they refuse here"
    app="$HOME/Applications/Lexicon.app"
    case "${1:-}" in
        quit)
            pid=$(daily_pid)
            [ -n "$pid" ] || { echo "live-lane: the daily Lexicon is not running"; return 0; }
            [ "$(ps -o comm= -p "$pid")" = "$app/Contents/MacOS/Lexicon" ] || die "the running daily Lexicon (pid $pid) is not $app; not quitting it"
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
            echo "$pid" > "$STATE/daily-quit"
            echo "live-lane: quit the daily Lexicon (pid $pid); sitting end reopens it (or: scripts/live-lane.sh daily reopen)"
            ;;
        reopen)
            if [ -n "$(daily_pid)" ]; then rm -f "$STATE/daily-quit"; echo "live-lane: the daily Lexicon is already running"; return 0; fi
            open "$app"
            rm -f "$STATE/daily-quit"
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
    # The folder never exists without its manifest, and each entry is listed
    # before it moves, so an interrupted park still restores.
    printf 'parked-by=live-lane.sh\nfrom=%s\n' "$DATA" > "$PARKED.manifest.$$"
    mkdir "$PARKED"
    mv "$PARKED.manifest.$$" "$PARKED/manifest"
    for path in "$DATA"/* "$DATA"/.[!.]*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        entry=${path##*/}
        kept "$entry" && continue
        printf 'entry=%s\n' "$entry" >> "$PARKED/manifest"
        mv "$path" "$PARKED/$entry"
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
    # Whatever the parked run wrote, and anything in the parked folder the
    # manifest doesn't name (a Finder .DS_Store), goes aside, never deleted.
    # An entry the manifest names that is no longer parked is already back
    # (an interrupted restore, or a park interrupted before its move): it stays.
    leftovers=$(mktemp -d "${TMPDIR:-/tmp}/lexicon-dev-unparked.XXXXXX")
    for path in "$DATA"/* "$DATA"/.[!.]*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        entry=${path##*/}
        kept "$entry" && continue
        if grep -qxF "entry=$entry" "$PARKED/manifest" && [ ! -e "$PARKED/$entry" ] && [ ! -L "$PARKED/$entry" ]; then continue; fi
        mv "$path" "$leftovers/$entry"
    done
    for path in "$PARKED"/* "$PARKED"/.[!.]*; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        entry=${path##*/}
        [ "$entry" != manifest ] || continue
        grep -qxF "entry=$entry" "$PARKED/manifest" || mv "$path" "$leftovers/parked-$entry"
    done
    sed -n 's/^entry=//p' "$PARKED/manifest" | while IFS= read -r entry; do
        [ -e "$PARKED/$entry" ] || [ -L "$PARKED/$entry" ] || continue
        mv "$PARKED/$entry" "$DATA/$entry"
    done
    # Every entry the manifest names is back in Dev's folder before the manifest goes.
    sed -n 's/^entry=//p' "$PARKED/manifest" | while IFS= read -r entry; do
        [ -e "$DATA/$entry" ] || [ -L "$DATA/$entry" ] || die "$entry is in neither $DATA nor $PARKED; the manifest is left in place"
    done
    rm "$PARKED/manifest"
    rmdir "$PARKED"
    if rmdir "$leftovers" 2>/dev/null; then leftovers=; fi
    echo "live-lane: restored $NAME's data${leftovers:+; what the parked run wrote is in $leftovers}"
}

# --- timers and idle -------------------------------------------------------------------

# A due timer is cleared only when the lane's holder reads it, so a builder's
# look at the queue never hides one from Live checks.
timers() {
    mine=
    if read_lock 2>/dev/null && holds; then mine=1; fi
    now=$(date +%s)
    for file in "$STATE"/timer.*; do
        [ -f "$file" ] || continue
        due=$(cat "$file")
        label=${file##*/timer.}
        if [ "$due" -le "$now" ]; then
            echo "timer $label: due"
            [ -z "$mine" ] || rm -f "$file"
        else
            echo "timer $label: due in $((due - now)) s"
        fi
    done
}

# Seconds since the last key press or mouse move from the hardware: CoreGraphics'
# HID system state, not IOHIDSystem's HIDIdleTime, which every posted key resets
# (the harness's own, and Dev's Cmd-V), so a second focus run waited out the first.
idle_seconds() {
    osascript -l JavaScript -e "ObjC.import('CoreGraphics'); Math.floor(\$.CGEventSourceSecondsSinceLastEventType(\$.kCGEventSourceStateHIDSystemState, 0xFFFFFFFF))" 2> /dev/null
}

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
        ! sitting_open || die "a sitting is open; sitting end closes it first"
        restore
        rm -f "$LOCK"
        echo "live-lane: $holder released the live-app lane"
        ;;
    status)
        if read_lock; then echo "live-lane: held by $holder (pid $pid)"; else echo "live-lane: free"; fi
        ! sitting_open || echo "live-lane: a $(sed -n 's/^hands-free=yes$/hands-free /p' "$MARKER")sitting is open (since $(sed -n 's/^opened=//p' "$MARKER"))"
        [ ! -e "$PARKED" ] || echo "live-lane: $NAME's data is parked"
        echo "live-lane: $(fn_listeners_line)"
        ;;
    check)
        require_lane
        ;;
    queue)
        fetch_issues
        remember_jake_items
        timers
        requests | awk -F'\t' '{ printf "%d. #%s %s (%s)\n", NR, $2, $3, $1 }'
        ;;
    idle)
        want=${2:-30}
        have=$(idle_seconds)
        [ -n "$have" ] || die "CoreGraphics gave no idle time"
        [ "$have" -ge "$want" ] || { echo "live-lane: Jake is at the keyboard (idle $have s, want $want s)" >&2; exit 1; }
        echo "live-lane: idle $have s"
        ;;
    timer)
        require_lane
        [ $# -eq 3 ] && [ "$2" -ge 0 ] 2>/dev/null || { echo "usage: live-lane.sh timer <seconds> <label>" >&2; exit 64; }
        mkdir -p "$STATE"
        echo $(($(date +%s) + $2)) > "$STATE/timer.$(printf %s "$3" | tr -c 'A-Za-z0-9._-' -)"
        # A long wait doesn't hold the lane, unless Dev's data is parked or a
        # sitting is open: those belong to the holder until it ends them.
        if [ -e "$PARKED" ] || sitting_open; then
            echo "live-lane: timer $3 due in $2 s; the lane stays held (parked data or an open sitting). queue shows it when due"
        else
            rm -f "$LOCK"
            echo "live-lane: timer $3 due in $2 s; released the lane meanwhile. Take it again when queue shows the timer due"
        fi
        ;;
    timers) timers ;;
    preflight)
        [ $# -eq 2 ] || { echo "usage: live-lane.sh preflight <issue>" >&2; exit 64; }
        fetch_issues
        remember_jake_items
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
