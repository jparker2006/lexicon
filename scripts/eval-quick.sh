#!/bin/sh
# eval-quick: the quick lexicon-eval for a speech or Cleanup change (#155): a
# relative score on Jake's Test set in about 20 minutes, not hours.
#
#   scripts/eval-quick.sh [--baseline <run.jsonl>] [--keep <run.jsonl>] [--lexicon <file>]
#                         [--manifest <manifest.jsonl>] [--scripted-gold]
#
# 1. The lag sample: the 30 lowest ids of the everyday split not in review (ids
#    are random, so a fixed draw), at the speed of speech.
# 2. Words and Terms: the whole everyday split at fast pace, with no lag. Local
#    Parakeet hears a clip the same at any pace; the run checks that on the
#    sample's clips and says so when they differ. No key reaches lexicon-eval, so
#    only the local model runs: a cloud or streaming engine hears at the speed of
#    speech, so it is scored by a full `lexicon-eval --manifest` run.
# 3. The scores and the compare with the baseline on the clips both hold, or
#    "no baseline yet" (scorer/score quick). The baseline is --baseline, else the
#    latest saved local Parakeet baseline (scripts/test-set.sh baselines).
#
# Clips still in Jake's gold review are left out with their sessions, and the
# scores say partial. --keep saves this run (the fast-pace lines, with the
# sample's realtime lines in their place) as a baseline for a later run: run it
# on main with --keep, then on the branch with --baseline. The Test set's runs
# never go in a git work tree.
#
# The eval stops at 30 minutes. It takes a build slot (scripts/lib/heavy.sh)
# when that exists. Defaults: the private Test set and the starter Lexicon. It
# prints counts, scores and paths only, never a clip: lexicon-eval's other
# messages can name one, so they are hidden. --manifest
# scorer/fixtures/manifest.jsonl --scripted-gold runs it on the public fixture
# with no model. Exit 0, 3 when a score is worse than the baseline, 1 on an
# error or at the time limit.
set -eu
umask 077
cd "$(dirname "$0")/.."

SAMPLE=30
LIMIT_MINUTES=30
DATA="$HOME/Library/Application Support/Lexicon"

manifest="$DATA/test-set/manifest.jsonl"
lexicon=
baseline=
keep=
scripted=
while [ $# -gt 0 ]; do
    case "$1" in
    --manifest | --lexicon | --baseline | --keep)
        [ $# -ge 2 ] || { echo "eval-quick: $1 needs a value" >&2; exit 2; }
        case "$1" in
        --manifest) manifest=$2 ;;
        --lexicon) lexicon=$2 ;;
        --baseline) baseline=$2 ;;
        --keep) keep=$2 ;;
        esac
        shift 2
        ;;
    --scripted-gold) scripted=--scripted-gold; shift ;;
    *)
        echo "usage: scripts/eval-quick.sh [--baseline <run.jsonl>] [--keep <run.jsonl>] [--lexicon <file>]" >&2
        echo "                             [--manifest <manifest.jsonl>] [--scripted-gold]" >&2
        exit 2
        ;;
    esac
done
[ -f "$manifest" ] || { echo "eval-quick: no manifest at $manifest" >&2; exit 1; }
if [ -z "$lexicon" ] && [ "$manifest" = "$DATA/test-set/manifest.jsonl" ] && [ -f "$DATA/starter-lexicon.txt" ]; then
    lexicon="$DATA/starter-lexicon.txt"
fi
if [ -z "$baseline" ]; then
    # Dated folders sort in time order.
    for saved in "$(dirname "$manifest")"/baselines/*/parakeet-everyday.jsonl; do
        [ -f "$saved" ] && baseline=$saved
    done
fi
if [ -n "$keep" ]; then
    [ ! -e "$keep" ] || { echo "eval-quick: --keep $keep already exists" >&2; exit 1; }
    repo=$(pwd -P)
    public() { case "$(cd "$(dirname "$1")" && pwd -P)/" in "$repo"/*) return 0 ;; esac; return 1; }
    if git -C "$(dirname "$keep")" rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
        ! { public "$manifest" && { [ -z "$lexicon" ] || public "$lexicon"; }; }; then
        echo "eval-quick: --keep is inside a git work tree but the Test set is private" >&2
        exit 1
    fi
fi

# A key would let a cloud engine run, at fast pace and at a cost.
for name in $(env | sed -n 's/^\(LEXICON_KEY_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$name"; done

if [ -f scripts/lib/heavy.sh ]; then
    . scripts/lib/heavy.sh  # holds a build slot until this script exits
fi
. scripts/lib/swift-flags.sh  # sets "$@" to the shared build flags
swift build "$@" --product lexicon-eval
bin="$(swift build "$@" --show-bin-path)/lexicon-eval"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
deadline=$(( $(date +%s) + LIMIT_MINUTES * 60 ))

# lexicon-eval on the everyday split until the deadline, its report in $1.json
# and its run in $1.jsonl. Only its messages that never name a clip are shown.
eval_run() {
    name=$1
    shift
    left=$(( deadline - $(date +%s) ))
    [ "$left" -gt 0 ] || { echo "eval-quick: stopped at the $LIMIT_MINUTES min limit" >&2; exit 1; }
    set -- --manifest "$manifest" --split everyday --out "$work/$name.jsonl" ${scripted:+"$scripted"} "$@"
    [ -z "$lexicon" ] || set -- "$@" --lexicon "$lexicon"
    [ -z "$baseline" ] || set -- "$@" --baseline "$baseline"
    status=0
    # Its temporary Histories hold copies of the clips: in $work, deleted on exit.
    TMPDIR="$work" perl -e 'alarm shift; exec @ARGV or die "eval-quick: cannot run lexicon-eval\n"' "$left" \
        "$bin" "$@" > "$work/$name.json" 2> "$work/$name.err" || status=$?
    tr '\r' '\n' < "$work/$name.err" | grep -E '^(lexicon-eval: skipping|lexicon-eval: Lexicon:|scored )' >&2 || true
    case "$status" in
    0 | 3) ;;
    142) echo "eval-quick: stopped at the $LIMIT_MINUTES min limit" >&2; exit 1 ;;
    *)
        hidden=$(tr '\r' '\n' < "$work/$name.err" | grep -cvE '^(lexicon-eval: [0-9]+/[0-9]+|lexicon-eval: loading|)$' || true)
        echo "eval-quick: lexicon-eval exited $status on the $name run ($hidden messages hidden: they can name a clip)" >&2
        exit 1
        ;;
    esac
}

echo "eval-quick: $manifest, everyday split; baseline: ${baseline:-none}"
echo "eval-quick: lag sample, $SAMPLE clips at the speed of speech"
eval_run realtime --sample "$SAMPLE"
echo "eval-quick: everyday split at fast pace"
eval_run fast --pace fast
status=0
scorer/score quick --fast-report "$work/fast.json" --fast-run "$work/fast.jsonl" \
    --realtime-report "$work/realtime.json" --realtime-run "$work/realtime.jsonl" ${keep:+--keep "$keep"} || status=$?
[ -z "$keep" ] || [ ! -f "$keep" ] || echo "eval-quick: kept this run as a baseline: $keep"
exit "$status"
