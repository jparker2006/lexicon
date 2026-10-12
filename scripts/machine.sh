#!/bin/sh
# machine: whether the Mac has room for another builder session, in one line,
# then the readings behind it. The orchestrator runs it before each chip.
#
#   scripts/machine.sh [--interval S]   S seconds between the two samples (default 3)
#
# The verdict is no when the 5-minute load is at or over 1 per core, the Mac
# pages out 50 or more pages a second, or under 15 percent of memory is free:
# M0's flakes and 5-minute checks came at a load of 13 and more on 10 cores,
# against about 0.5 per core with four builders. Build slots in use are shown
# but never make it no: heavy jobs already wait for a slot, and a builder spends
# most of its time not building. Low Power Mode is a warning, never a no; only
# Jake changes it. The top processes outside Lexicon's own builds, by CPU used
# between the two samples, show what else is taking the cores.
set -eu
cd "$(dirname "$0")/.."

interval=3
[ "${1:-}" = --interval ] && interval=${2:?usage: machine.sh [--interval S]}
slots="$HOME/Library/Application Support/Lexicon Dev/heavy"

pageouts() { vm_stat | awk '/^Pageouts:/ { gsub(/\./, "", $2); print $2 }'; }
# CPU seconds so far per process: "pid seconds command".
cpu() {
    ps -Ao pid=,time=,comm= | awk '{
        n = split($2, t, ":"); s = t[n] + 60 * t[n - 1] + (n > 2 ? 3600 * t[n - 2] : 0)
        c = $0; sub(/^ *[0-9]+ +[0-9:.]+ +/, "", c)
        printf "%s %.2f %s\n", $1, s, c }'
}

ps1=$(cpu)
out1=$(pageouts)
sleep "$interval"
ps2=$(cpu)
out2=$(pageouts)

set -- $(sysctl -n hw.ncpu vm.loadavg | tr -d '{}')
cores=$1
load5=$3
free=$(memory_pressure -Q | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p')
lowpower=$(pmset -g | awk '/lowpowermode/ { print $2 }')

in_use=0
known=0
for n in 1 2; do
    [ -f "$slots/slot$n" ] || continue
    known=$((known + 1))
    st=0
    lockf -s -n -t 0 "$slots/slot$n" true 2> /dev/null || st=$?
    [ "$st" -eq 75 ] && in_use=$((in_use + 1))
done
if [ "$known" -eq 2 ]; then slot_line="build slots $in_use of 2 in use"; else slot_line="build slots unknown"; fi

per_core=$(awk -v l="$load5" -v c="$cores" 'BEGIN { printf "%.2f", l / c }')
rate=$(awk -v a="$out1" -v b="$out2" -v s="$interval" 'BEGIN { printf "%d", (b - a) / (s > 0 ? s : 1) }')

why=
add() { why="$why${why:+; }$1"; }
awk -v p="$per_core" 'BEGIN { exit !(p >= 1) }' && add "load $load5 over 5 min on $cores cores"
[ "$rate" -ge 50 ] && add "paging out $rate pages/s"
[ -n "$free" ] && [ "$free" -lt 15 ] && add "memory $free% free"

if [ -n "$why" ]; then echo "room for more builders: no ($why)"; else echo "room for more builders: yes"; fi
echo "  load $per_core per core (5 min) | pageouts $rate/s | memory ${free:-?}% free | $slot_line | Low Power Mode $([ "$lowpower" = 1 ] && echo on || echo off)"
if [ "$lowpower" = 1 ]; then
    echo "  warning: Low Power Mode is on, so builds run slower. Only Jake turns it off."
fi
for n in 1 2; do
    [ -f "$slots/slot$n.holder" ] && [ "$in_use" -gt 0 ] && echo "  slot $n: $(head -n 1 "$slots/slot$n.holder")"
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
