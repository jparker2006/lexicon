#!/bin/sh
# dev-run: build the dev app, install it to ~/Applications/Lexicon Dev.app and
# launch it with `open`. Never touches the daily copy (~/Applications/Lexicon.app).
#
#   scripts/dev-run.sh                       debug build
#   scripts/dev-run.sh --release             release build (for measuring budgets)
#   scripts/dev-run.sh [--release] -- ARGS   pass ARGS to the app, e.g. -- --test-hooks
#   scripts/dev-run.sh --no-fn [...]         a run for WAV-hook or Accessibility checks only
#
# It refuses while another app that answers fn runs (scripts/lib/fn-listeners.sh),
# since every fn result from that run would be wrong. A --no-fn run goes ahead
# and says who else is listening: none of its checks may use fn.
#
# Launch with this (or `open`), never by running the binary: a binary run from a
# shell inherits the shell's Accessibility trust and fakes permissions, so the app
# refuses to start that way. Same certificate and bundle id every build, so the
# dev app keeps its Accessibility and Microphone grants across rebuilds.
#
# Only the live-app lane's holder runs this (scripts/live-lane.sh). Within it,
# a second lock stops two runs swapping the dev app at once.
set -eu
cd "$(dirname "$0")/.."
RELEASE=
FN=1
while [ $# -gt 0 ]; do
    case "$1" in
        --release) RELEASE=--release ;;
        --no-fn) FN= ;;
        --) shift; break ;;
        *) echo "usage: dev-run.sh [--release] [--no-fn] [-- app args]" >&2; exit 64 ;;
    esac
    shift
done

scripts/live-lane.sh check
. scripts/lib/fn-listeners.sh
if [ -n "$FN" ]; then
    require_no_fn_listeners || { echo "dev-run: for WAV-hook or Accessibility-only checks, rerun with --no-fn." >&2; exit 1; }
    echo "dev-run: $(fn_listeners_line)" >&2
else
    echo "dev-run: --no-fn, so no fn checks on this run; $(fn_listeners_line)" >&2
fi

APP=$(scripts/bundle.sh dev $RELEASE)
exec lockf -k -t 600 "${TMPDIR:-/tmp}/dev.jparker.lexicon.dev.install.lock" scripts/lib/install-app.sh dev "$APP" "$@"
