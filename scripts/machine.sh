#!/bin/sh
# machine: whether the Mac has room for another builder session, in one line,
# then the readings behind it. The orchestrator runs it before each chip.
#
#   scripts/machine.sh [--interval S]   S seconds between the two samples (default 3)
#
# The verdict and its rule are in scripts/lib/verdict.sh, which the build slots
# also ask before a third slot. Build slots in use and the jobs waiting for one
# are shown but never make it no: heavy jobs already wait in line, and a builder
# spends most of its time not building. Low Power Mode is a warning, never a no;
# only Jake changes it. The top processes outside Lexicon's own builds, by CPU
# used between the two samples, show what else is taking the cores.
set -eu
cd "$(dirname "$0")/.."

interval=3
[ "${1:-}" = --interval ] && interval=${2:?usage: machine.sh [--interval S]}
. scripts/lib/heavy.sh

# CPU seconds so far per process: "pid seconds command".
cpu() {
    ps -Ao pid=,time=,comm= | awk '{
        n = split($2, t, ":"); s = t[n] + 60 * t[n - 1] + (n > 2 ? 3600 * t[n - 2] : 0)
        c = $0; sub(/^ *[0-9]+ +[0-9:.]+ +/, "", c)
        printf "%s %.2f %s\n", $1, s, c }'
}

ps1=$(cpu)
out1=$(verdict_pageouts)
sleep "$interval"
ps2=$(cpu)
out2=$(verdict_pageouts)

verdict_status=0
verdict "$out1" "$out2" "$interval" || verdict_status=$?
lowpower=$(pmset -g | awk '/lowpowermode/ { print $2 }')

if [ "$verdict_status" -ne 0 ]; then echo "room for more builders: no ($verdict_why)"; else echo "room for more builders: yes"; fi
echo "  load $verdict_per_core per core (5 min) | pageouts $verdict_rate/s | memory ${verdict_free:-?}% free | $(heavy_summary) | Low Power Mode $([ "$lowpower" = 1 ] && echo on || echo off)"
if [ "$lowpower" = 1 ]; then
    echo "  warning: Low Power Mode is on, so builds run slower. Only Jake turns it off."
fi
for n in 1 2 3; do
    if [ -f "$HEAVY_DIR/slot$n.holder" ] && heavy_held "$n"; then echo "  slot $n: $(heavy_holder "$n")"; fi
done

# Lexicon's own work (builds, tests, the app, sessions' tools) is expected load;
# the list is for what else takes the cores.
top=$(printf '%s\n%s\n' "$ps1" "--" "$ps2" | awk -v s="$interval" '
    $0 == "--" { second = 1; next }
    !second { before[$1] = $2; next }
    {
        c = $0; sub(/^[0-9]+ +[0-9.]+ +/, "", c)
        if (c ~ /[Ll]exicon|swift|clang|\/ld$|xctest|llvm/) next
        if (!($1 in before)) next
        pct = ($2 - before[$1]) * 100 / (s > 0 ? s : 1)
        if (pct >= 1) { n = split(c, p, "/"); printf "%d %s\n", pct, p[n] }
    }' | sort -rn | head -n 3 | awk '{ c = $0; sub(/^[0-9]+ /, "", c); printf "%s%s %d%%", (NR > 1 ? ", " : ""), c, $1 }')
echo "  top other processes: ${top:-none over 1% of a core}"
