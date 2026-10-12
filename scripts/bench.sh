#!/bin/sh
# bench: one budget measured on a branch build (A) against main (B), interleaved
# A B A B under the same load, at least 5 runs per side, with the machine's load
# recorded every 0.5 s. A number taken under load is provisional: the verdict
# says so instead of passing or failing it.
#
#   scripts/bench.sh <budget> <A.app> <B.app> [runs per side]   default 5
#   scripts/bench.sh background [seconds]    measure the quiet Mac's load (default 60 s)
#   scripts/bench.sh sample <file>           the load sampler alone, until stopped
#   scripts/bench.sh report <budget> <A numbers> <B numbers> <load file> [same]
#
# Budgets, each with one reading and its exclusion rule, fixed before the first run:
#   history-open  History window, open to first rows, every open, p95 100 ms or less.
#                 Excludes nothing. Needs debug bundles: the harness opens it through test hooks.
#                 Needs a History with older days to scroll to (the harness's history check
#                 waits for them), such as the synthetic year Live checks seeds.
#   launch        process start to fn working, warm relaunch with `open`, p95 150 ms or less.
#                 Excludes each install's first launch (macOS checks the new signature).
#
# A and B are Lexicon Dev bundles from scripts/bundle.sh, each built at its own
# commit. Each run installs one with scripts/lib/install-app.sh and reads the
# app's own log lines, so only the live-app lane's holder runs this. The
# verdict is PROVISIONAL, never PASS or FAIL, while the run's median load is
# over 1.5 times the measured background, or another app answers fn. When A
# and B build the same app code, the verdict is SAME APP CODE: their
# difference is run-to-run noise, and the budget is read from main's numbers.
set -eu
HERE=$PWD
cd "$(dirname "$0")/.."
. scripts/lib/flavor.sh
. scripts/lib/fn-listeners.sh
flavor dev

BACKGROUND="$HOME/Library/Application Support/$NAME/live-lane/bench-background"
APP="$APP_PATH"

die() { echo "bench: $*" >&2; exit 1; }

budget() {
    case "$1" in
        history-open)
            TARGET=100
            READING="History window, open to first rows (the app's \"first rows drawn\" line), every open"
            EXCLUDES="nothing"
            ;;
        launch)
            TARGET=150
            READING="process start to fn working (the app's launch line), warm relaunch with open"
            EXCLUDES="each install's first launch"
            ;;
        *) die "unknown budget '$1': history-open or launch" ;;
    esac
}

load1() { sysctl -n vm.loadavg | awk '{ print $2 }'; }

power() {
    source=$(pmset -g batt | sed -n "s/.*drawing from '\([^']*\)'.*/\1/p")
    lowpower=$(pmset -g | awk '$1 == "lowpowermode" { print $2 }')
    echo "# power: ${source:-unknown}, low power mode ${lowpower:-unknown}"
}

sample() {
    power >> "$1"
    while :; do
        echo "$(date +%s) $(load1)" >> "$1"
        sleep 0.5
    done
}

# Reads numbers on stdin; prints "n p50 p95" (nearest rank, as lag-report.sh).
percentiles() {
    sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print "0 - -"; exit }
        printf "%d %d %d\n", NR, v[int((NR * 50 + 99) / 100)], v[int((NR * 95 + 99) / 100)]
    }'
}

# Load samples on stdin; prints "min median max n".
load_stats() {
    grep -v '^#' | awk '{ print $2 }' | sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print "- - - 0"; exit }
        printf "%.2f %.2f %.2f %d\n", v[1], v[int((NR + 1) / 2)], v[NR], NR
    }'
}

report() {
    budget "$1"
    same=${5:-}
    set -- $(percentiles < "$2") $(percentiles < "$3") $(load_stats < "$4")
    a_n=$1 a50=$2 a95=$3 b_n=$4 b50=$5 b95=$6 lmin=$7 lmed=$8 lmax=$9
    echo "A (branch): $a_n samples, p50 $a50 ms, p95 $a95 ms"
    echo "B (main):   $b_n samples, p50 $b50 ms, p95 $b95 ms"
    echo "load: min $lmin, median $lmed, max $lmax"
    [ "$a_n" -gt 0 ] && [ "$b_n" -gt 0 ] || { echo "FAIL: no samples on one side"; return 1; }
    printf 'A - B: p50 %+d ms, p95 %+d ms\n' $((a50 - b50)) $((a95 - b95))
    provisional=
    if [ -s "$BACKGROUND" ]; then
        background=$(cat "$BACKGROUND")
        if awk -v m="$lmed" -v b="$background" 'BEGIN { exit !(m > 1.5 * b) }'; then
            provisional="median load $lmed is over 1.5 times the background $background"
        fi
    else
        provisional="no background load measured (scripts/bench.sh background on a quiet Mac)"
    fi
    listeners=$(fn_listeners_line)
    [ "$listeners" = "fn listeners: none" ] || provisional="${provisional:+$provisional; }$listeners"
    if [ -n "$provisional" ]; then
        echo "PROVISIONAL, no final verdict: $provisional. A's p95 $a95 ms against the $TARGET ms budget."
    elif [ "$same" = same ]; then
        echo "SAME APP CODE: A and B build the same Sources, so A - B is run-to-run noise. Main's p95 $b95 ms against the $TARGET ms budget."
    elif [ "$a95" -le "$TARGET" ]; then
        echo "PASS: A's p95 $a95 ms is within the $TARGET ms budget."
    else
        echo "FAIL: A's p95 $a95 ms is over the $TARGET ms budget."
        return 1
    fi
}

running_pid() { pgrep -f "^$APP/Contents/MacOS/" | head -1; }

# Lines from Lexicon Dev's log since $1, category $2, matching sed expression $3.
log_numbers() {
    /usr/bin/log show --start "$1" --style compact --predicate \
        "category == \"$2\" && processImagePath CONTAINS \"/$NAME.app/\"" | sed -n "$3"
}

# One run of one side: install the bundle, then append its samples to $2. $3 names the side.
run() {
    rm -rf "$OUT/stage.app"
    ditto "$1" "$OUT/stage.app"
    case "$BUDGET" in
        history-open)
            scripts/lib/install-app.sh dev "$OUT/stage.app" --test-hooks > /dev/null
            since=$(date '+%Y-%m-%d %H:%M:%S')
            scripts/harness.sh history > "$OUT/harness.log" 2>&1 \
                || die "the harness's History check failed on $3 (run $RUN), so no verdict: $(tail -1 "$OUT/harness.log"). It needs a History with older days to scroll to."
            log_numbers "$since" History 's/.*first rows drawn \([0-9][0-9]*\) ms after open.*/\1/p' >> "$2"
            ;;
        launch)
            scripts/lib/install-app.sh dev "$OUT/stage.app" > /dev/null
            for _ in 1 2 3; do
                pid=$(running_pid)
                [ -z "$pid" ] || { kill -TERM "$pid"; while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done; }
                since=$(date '+%Y-%m-%d %H:%M:%S')
                open "$APP"
                sleep 3
                log_numbers "$since" launch 's/.*fn working \([0-9][0-9]*\) ms after process start.*/\1/p' | tail -1 >> "$2"
            done
            ;;
    esac
}

case "${1:-}" in
    background)
        scripts/live-lane.sh check
        seconds=${2:-60}
        file=$(mktemp -t bench)
        sample "$file" &
        sampler=$!
        trap 'kill "$sampler" 2>/dev/null || true; rm -f "$file"' EXIT
        trap 'exit 130' INT TERM HUP
        sleep "$seconds"
        kill "$sampler"
        wait "$sampler" 2>/dev/null || true
        median=$(load_stats < "$file" | cut -d' ' -f2)
        rm -f "$file"
        mkdir -p "$(dirname "$BACKGROUND")"
        echo "$median" > "$BACKGROUND"
        echo "bench: background load $median (median of $seconds s), saved for later verdicts"
        ;;
    sample)
        [ $# -eq 2 ] || { echo "usage: bench.sh sample <file>" >&2; exit 64; }
        sample "$2"
        ;;
    report)
        [ $# -eq 5 ] || [ $# -eq 6 ] || { echo "usage: bench.sh report <budget> <A numbers> <B numbers> <load file> [same]" >&2; exit 64; }
        report "$2" "$3" "$4" "$5" "${6:-}"
        ;;
    history-open | launch)
        BUDGET=$1
        [ $# -eq 3 ] || [ $# -eq 4 ] || { echo "usage: bench.sh <budget> <A.app> <B.app> [runs per side]" >&2; exit 64; }
        RUNS=${4:-5}
        # Bundle paths are the caller's, not the repo root's.
        A=$2; case "$A" in /*) ;; *) A="$HERE/$A" ;; esac
        B=$3; case "$B" in /*) ;; *) B="$HERE/$B" ;; esac
        set -- "$1" "$A" "$B"
        [ "$RUNS" -ge 5 ] 2>/dev/null || die "$RUNS run(s) per side is too few to tell A from B under changing load: at least 5"
        for bundle in "$2" "$3"; do
            [ "$(plutil -extract CFBundleIdentifier raw "$bundle/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] \
                || die "$bundle is not a $NAME bundle (scripts/bundle.sh dev)"
        done
        scripts/live-lane.sh check
        budget "$BUDGET"
        OUT=$(mktemp -d "${TMPDIR:-/tmp}/bench.XXXXXX")
        commit() { plutil -extract LexiconCommit raw "$1/Contents/Info.plist" 2>/dev/null || echo unknown; }
        echo "bench: $BUDGET, $RUNS runs per side interleaved, A $(commit "$2") against B $(commit "$3")"
        echo "reading: $READING; budget p95 $TARGET ms"
        echo "excluded: $EXCLUDES"
        echo "$(fn_listeners_line); $(power | sed 's/^# //'); samples in $OUT"
        sample "$OUT/load.txt" &
        sampler=$!
        trap 'kill "$sampler" 2>/dev/null || true' EXIT
        trap 'exit 130' INT TERM HUP
        : > "$OUT/A.txt"
        : > "$OUT/B.txt"
        i=0
        while [ "$i" -lt "$RUNS" ]; do
            i=$((i + 1))
            # Alternate which side goes first, so neither always follows the other.
            RUN=$i
            if [ $((i % 2)) -eq 1 ]; then run "$2" "$OUT/A.txt" A; run "$3" "$OUT/B.txt" B
            else run "$3" "$OUT/B.txt" B; run "$2" "$OUT/A.txt" A
            fi
        done
        kill "$sampler"
        wait "$sampler" 2>/dev/null || true
        power >> "$OUT/load.txt"
        # The same app code on both sides: no difference between them can be a regression.
        same=
        a=$(commit "$2") b=$(commit "$3")
        case "$a$b" in
            *dirty* | *unknown*) ;;
            *) if git diff --quiet "$a" "$b" -- Sources Package.swift Package.resolved scripts/app 2>/dev/null; then same=same; fi ;;
        esac
        report "$BUDGET" "$OUT/A.txt" "$OUT/B.txt" "$OUT/load.txt" $same
        ;;
    *)
        echo "usage: bench.sh history-open|launch <A.app> <B.app> [runs] | background [s] | sample <file> | report ..." >&2
        exit 64
        ;;
esac
