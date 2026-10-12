# Sourced by scripts/test-gh/run.sh into each test's subshell.
#
#   use_fixture <name>    copies fixtures/<name> to a fresh folder; the fake gh reads it
#   use_fakes             puts the fake sysctl, vm_stat, ps, ... first on PATH too
#   run <script> [args]   runs scripts/<script>; sets $out, $err and $status
#   expect_status, expect_out, expect_no_out, expect_err, expect_log, fail
set -eu
TESTS=$(cd "$(dirname "$file")" && pwd)
ROOT=$(cd "$TESTS/../.." && pwd)
TMP=$(mktemp -d -t test-gh)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME"
export GH_LOG="$TMP/gh.log"
: > "$GH_LOG"
export PATH="$TESTS/bin:$PATH"
export LEXICON_NOW=2026-10-10T12:00:00Z
export TZ=America/Los_Angeles
SCRIPTS=$ROOT/scripts

use_fixture() {
    rm -rf "$TMP/gh"
    cp -R "$TESTS/fixtures/$1" "$TMP/gh"
    export GH_FIXTURES="$TMP/gh"
}

use_fakes() {
    export PATH="$TESTS/fake:$PATH"
}

run() {
    script=$1
    shift
    status=0
    "$SCRIPTS/$script" "$@" > "$TMP/out" 2> "$TMP/err" || status=$?
    out=$(cat "$TMP/out")
    err=$(cat "$TMP/err")
}

fail() {
    echo "$*"
    echo "--- stdout"
    printf '%s\n' "${out:-}"
    echo "--- stderr"
    printf '%s\n' "${err:-}"
    exit 1
}

expect_status() { [ "$status" -eq "$1" ] || fail "expected exit $1, got $status"; }
expect_out() { printf '%s\n' "$out" | grep -F -q -- "$1" || fail "stdout lacks: $1"; }
expect_no_out() { ! printf '%s\n' "$out" | grep -F -q -- "$1" || fail "stdout has: $1"; }
expect_err() { printf '%s\n' "$err" | grep -F -q -- "$1" || fail "stderr lacks: $1"; }
expect_log() { grep -F -q -- "$1" "$GH_LOG" || fail "gh log lacks: $1 (log: $(cat "$GH_LOG"))"; }
expect_no_log() { ! grep -F -q -- "$1" "$GH_LOG" || fail "gh log has: $1"; }
expect_count() {
    n=$(printf '%s\n' "$out" | grep -F -c -- "$2" || true)
    [ "$n" -eq "$1" ] || fail "expected $1 lines with '$2', got $n"
}
