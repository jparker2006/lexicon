# fn-listeners: sourced by the scripts whose results depend on fn.
#
# Other apps that answer fn and paste: Jake's daily Lexicon, any other copy of
# Lexicon or Lexicon Dev, and his prototypes. While one runs, every fn press
# (real or synthetic) dictates into it too, and its Cmd-V counts as typing for
# Lexicon Dev's late-text guard, so Dev holds its own text as typedSince while
# the other app's paste lands (#141). So an fn-dependent step refuses instead
# of warning. WAV-hook and Accessibility-only checks don't need fn and still run.
#
# Matched by executable path (ps comm), not by command line, so a shell or a
# grep whose arguments mention a path is never mistaken for the app.

# Prints one "pid|what|path" line per other fn listener.
fn_listeners() {
    ps -axo pid=,comm= | while read -r pid path; do
        case "$path" in
            "$HOME/Applications/Lexicon.app/Contents/MacOS/"*) what="the daily Lexicon" ;;
            "$HOME/Applications/Lexicon Dev.app/Contents/MacOS/"*) continue ;;
            */Lexicon.app*/Contents/MacOS/*) what="a copy of Lexicon" ;;
            *"/Lexicon Dev.app"*/Contents/MacOS/*) what="a second Lexicon Dev" ;;
            */"Lexicon Indicator"*) what="Lexicon Indicator" ;;
            */RespeakProto*) what="RespeakProto" ;;
            *) continue ;;
        esac
        echo "$pid|$what|$path"
    done
}

# One line for result headers: "fn listeners: none", or who is running.
fn_listeners_line() {
    found=$(fn_listeners | awk -F'|' '{ printf "%s%s (pid %s)", (NR > 1 ? ", " : ""), $2, $1 }')
    echo "fn listeners: ${found:-none}"
}

# A warning only, for checks that don't use fn but are worth a note.
warn_fn_listeners() {
    fn_listeners | while IFS='|' read -r pid what path; do
        echo "warning: $what is running (pid $pid). It answers fn too: fn checks refuse while it runs." >&2
    done
}

# Fails, naming each listener, while any other fn listener runs.
require_no_fn_listeners() {
    found=$(fn_listeners)
    [ -n "$found" ] || return 0
    printf '%s\n' "$found" | while IFS='|' read -r pid what path; do
        if [ "$what" = "the daily Lexicon" ]; then
            echo "The daily Lexicon is running (pid $pid) and answers fn, so Dev's fn results would be wrong. Quit it from its menu bar (scripts/live-lane.sh daily quit), then rerun." >&2
        else
            echo "$what is running (pid $pid, $path) and answers fn, so Dev's fn results would be wrong. Quit it, then rerun." >&2
        fi
    done
    return 1
}
