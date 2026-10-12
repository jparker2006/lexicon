#!/bin/sh
# lag-report: fn-up to text p50 and p95, and fn-down to first audio, from the
# unified log's one line per Dictation. Numbers only: no Dictation text is read.
#
#   scripts/lag-report.sh [--daily] [--load <file>] [period]    period as `log show --last` takes it, default 2h
#
# --load reads a load sampler file (scripts/bench.sh sample <file>, run for the
# same period) and adds the load and power state the numbers were taken under:
# a lag taken under load is provisional.
#
# Lexicon Dev by default; --daily reads Jake's own copy. Lag is fn-up to the
# target app reading the paste (`Conductor.land`); the start gap is fn-down to
# the first buffer (`CaptureCore`). Test-hook WAV Dictations count too: read a
# period with only fn Dictations in it for the fn numbers. Percentiles are nearest-rank.
set -eu
APP="Lexicon Dev.app"
LOAD=
if [ "${1:-}" = --daily ]; then APP="Lexicon.app"; shift; fi
if [ "${1:-}" = --load ]; then LOAD=${2:?usage: lag-report.sh [--daily] [--load <file>] [period]}; shift 2; fi
PERIOD=${1:-2h}

lines() {
    /usr/bin/log show --last "$PERIOD" --style compact --predicate \
        "subsystem == \"Lexicon\" && category == \"$1\" && processImagePath CONTAINS \"/$APP/\""
}

# Reads numbers on stdin, prints "n, p50 X ms, p95 Y ms".
percentiles() {
    sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print "none"; exit }
        p50 = int((NR * 50 + 99) / 100); p95 = int((NR * 95 + 99) / 100)
        printf "%d, p50 %d ms, p95 %d ms, max %d ms\n", NR, v[p50], v[p95], v[NR]
    }'
}

echo "$APP, last $PERIOD"
printf 'fn-up to text (typed Dictations): '
lines dictation | sed -n 's/.*: lag \([0-9][0-9]*\) ms,.*/\1/p' | percentiles
printf 'fn-down to first audio: '
lines audio | sed -n 's/.*start gap \([0-9][0-9]*\) ms.*/\1/p' | percentiles
printf 'outcomes: '
lines dictation | sed -n 's/.*Dictation [0-9A-F-]* \([a-zA-Z]*\):.*/\1/p' | sort | uniq -c | awk '{ printf "%s %d  ", $2, $1 } END { print "" }'
if [ -n "$LOAD" ]; then
    printf 'load: '
    grep -v '^#' "$LOAD" | awk '{ print $2 }' | sort -n | awk '{ v[NR] = $1 } END {
        if (NR == 0) { print "no samples"; exit }
        printf "min %.2f, median %.2f, max %.2f (%d samples)\n", v[1], v[int((NR + 1) / 2)], v[NR], NR
    }'
    sed -n 's/^# power: /power: /p' "$LOAD" | sort -u
fi
