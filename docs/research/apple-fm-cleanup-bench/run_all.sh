#!/bin/bash
# Runs the Apple Foundation Models matrix one process at a time, with nothing else running.
#
#   run_all.sh <path to built AppleFMBench> [results dir]
#
# Build first (outside the repo, so .build stays out of git):
#   swift build -c release --package-path docs/research/apple-fm-cleanup-bench --scratch-path <scratch>/build
#
# Each block writes results/<config>-<scope>-lead<ms>.jsonl and logs the power source and Low Power Mode
# state to results/run.log. Blocks resume from their file if it already has rows.
set -u

BIN="${1:?usage: run_all.sh <AppleFMBench binary> [results dir]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${2:-$HERE/results}"
mkdir -p "$OUT"
LOG="$OUT/run.log"

power_state() {
    pmset -g batt | head -1
    pmset -g | grep -m1 lowpowermode
}

block() {
    local cfg="$1" scope="$2" runs="$3" lead="$4"
    local name="${cfg}-${scope}-lead${lead}"
    echo "== $(date '+%Y-%m-%d %H:%M:%S') start $name runs=$runs" >> "$LOG"
    power_state >> "$LOG"
    "$BIN" --cases "$HERE/cases.json" --config "$cfg" --scope "$scope" --runs "$runs" \
        --warmup 3 --lead-ms "$lead" --out "$OUT/$name.jsonl" 2>> "$LOG"
    local rc=$?
    echo "== $(date '+%Y-%m-%d %H:%M:%S') end $name (exit $rc)" >> "$LOG"
    power_state >> "$LOG"
}

"$BIN" --availability >> "$LOG" 2>&1

# Primary matrix: 10 runs per case, lead 0 (the request goes out right after prewarm).
block rules-text whole 10 0
block examples-text whole 10 0
block rules-text tail 10 0
block examples-text tail 10 0
block rules-generable whole 10 0
block examples-generable whole 10 0
block rules-generable tail 10 0
block examples-generable tail 10 0
# Extras: a realistic lead between prewarm and fn-up, and the permissive guardrails.
block examples-text whole 3 2000
block examples-text-permissive whole 1 0

echo "== $(date '+%Y-%m-%d %H:%M:%S') all blocks done" >> "$LOG"
