# fn-listeners: sourced by scripts/dev-run.sh and scripts/harness.sh.
#
# Other apps that answer fn and paste: Jake's daily Lexicon and his prototypes.
# While one runs, every real fn press dictates into it too, and its Cmd-V counts
# as typing for Lexicon Dev's late-text guard, so Dev holds its own text as
# typedSince while the other app's paste lands (#141). A warning only: these
# are Jake's apps, and only he quits them.

warn_fn_listeners() {
    # name|what its command line contains
    for listener in "the daily Lexicon|$HOME/Applications/Lexicon.app/Contents/MacOS/" \
        "Lexicon Indicator|Lexicon Indicator" "RespeakProto|RespeakProto"; do
        pids=$(pgrep -f "${listener#*|}" | tr '\n' ' ')
        if [ -n "$pids" ]; then
            echo "warning: ${listener%%|*} is running (pid ${pids% }). It answers fn too: for real fn insert checks, ask Jake to quit it first." >&2
        fi
    done
}
