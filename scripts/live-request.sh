#!/bin/sh
# live-request: a builder's request to the Live checks session, posted as one
# comment on its issue headed `Live checks request: <branch> @ <sha7>`. The
# Live checks session reads the queue in arrival order (scripts/live-lane.sh
# queue): hands-off items run as soon as Jake isn't typing, and Jake's items
# wait for a scheduled sitting.
#
#   scripts/live-request.sh post <issue> <items file>   check the tree and the items, then post
#   scripts/live-request.sh items <file | ->             check the items; one tab-separated line each
#
# The items file has one block per item, blank lines between, each field once:
#
#   item: Hold                    a short title
#   kind: jake                    hands-off (a hook, the harness or a script runs it) or jake (his hands)
#   gesture: hold fn 1 to 2 s, four times
#   target: Live checks' own test window
#   speak: no                     yes or no: does Jake speak during it
#   fn: yes                       yes or no: does it use fn, real or synthetic (every Dictation does)
#   cue: the start sound          what says the gesture can begin or end
#   observable: began, confirmed(hold), fn up, stopped in the fn log
#   pass: confirmed(hold) 0.28 to 0.32 s after began, every hold
#   needs: none                   ";" between: #N (merged first), a Swift name the head must use, or a step done first
#   minutes: 2                    jake items only: Jake's time for it
#
# Anything a hook, the harness or a headless run can check is hands-off: Jake
# would rather go hands-free than do it. A new request replaces the issue's
# earlier one, so it lists every item still to run; Live checks answers the
# whole request with one `Live checks: <branch> @ <sha7>` result. `items -` reads a whole request
# comment too, and checks only its live-items block.
set -eu
HERE=$PWD
cd "$(dirname "$0")/.."

die() { echo "live-request: $*" >&2; exit 1; }
# A relative items file is the caller's, not the repo root's.
here() { case "$1" in - | /*) echo "$1" ;; *) echo "$HERE/$1" ;; esac; }

# The live-items block of a comment, or the whole input when it has none.
block() {
    if grep -q '^```live-items' "$1"; then
        sed -n '/^```live-items/,/^```$/p' "$1" | sed '1d;$d'
    else
        cat "$1"
    fi
}

# Prints n, item, kind, gesture, target, speak, fn, cue, observable, pass, needs and
# minutes per item, tab-separated. Names every missing or bad field, then fails.
parse() {
    block "$1" | awk '
        BEGIN {
            nf = split("item kind gesture target speak fn cue observable pass needs", required, " ")
            for (i = 1; i <= nf; i++) known[required[i]] = 1
            known["minutes"] = 1
        }
        function bad(why) { printf "live-request: item %d%s: %s\n", n, (v["item"] != "" ? " (" v["item"] ")" : ""), why > "/dev/stderr"; errors++ }
        function flush(   i, ok) {
            if (!open) return
            open = 0
            before = errors
            for (i = 1; i <= nf; i++) if (v[required[i]] == "") bad("no " required[i] " field")
            if (v["kind"] != "" && v["kind"] != "hands-off" && v["kind"] != "jake") bad("kind is \"" v["kind"] "\", not hands-off or jake")
            if (v["speak"] != "" && v["speak"] != "yes" && v["speak"] != "no") bad("speak is \"" v["speak"] "\", not yes or no")
            if (v["fn"] != "" && v["fn"] != "yes" && v["fn"] != "no") bad("fn is \"" v["fn"] "\", not yes or no")
            if (v["kind"] == "jake" && v["minutes"] == "") bad("no minutes field (Jake'"'"'s time for it, whole minutes)")
            else if (v["kind"] == "jake" && v["minutes"] !~ /^[1-9][0-9]*$/) bad("minutes is \"" v["minutes"] "\", not whole minutes")
            for (i = 0; i < nbad; i++) bad(pending[i])
            nbad = 0
            if (errors == before)
                print n "\t" v["item"] "\t" v["kind"] "\t" v["gesture"] "\t" v["target"] "\t" v["speak"] "\t" v["fn"] "\t" v["cue"] "\t" v["observable"] "\t" v["pass"] "\t" v["needs"] "\t" (v["kind"] == "jake" ? v["minutes"] : 0)
            split("", v)
        }
        /^[ \t]*$/ { flush(); next }
        {
            if (!open) { open = 1; n++ }
            i = index($0, ":")
            key = i ? substr($0, 1, i - 1) : ""
            value = i ? substr($0, i + 1) : ""
            gsub(/^[ \t]+|[ \t]+$/, "", key)
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            gsub(/\t/, " ", value)
            if (!(key in known)) { pending[nbad++] = "\"" $0 "\" is not a field"; next }
            if (key in v) { pending[nbad++] = "two " key " fields"; next }
            v[key] = value
        }
        END {
            flush()
            if (n == 0) { print "live-request: no items" > "/dev/stderr"; errors++ }
            exit errors > 0
        }'
}

case "${1:-}" in
    items)
        [ $# -eq 2 ] || { echo "usage: live-request.sh items <file | ->" >&2; exit 64; }
        if [ "$2" = - ]; then
            input=$(mktemp -t live-request)
            trap 'rm -f "$input"' EXIT
            cat > "$input"
            parse "$input"
        else
            parse "$(here "$2")"
        fi
        ;;
    post)
        [ $# -eq 3 ] || { echo "usage: live-request.sh post <issue> <items file>" >&2; exit 64; }
        issue=${2#\#}
        file=$(here "$3")
        [ -z "$(git status --porcelain)" ] || die "the tree has uncommitted changes; commit and push them, so the request names exactly what Live checks runs"
        branch=$(git symbolic-ref --short -q HEAD) || die "HEAD is detached; check out your branch"
        head=$(git rev-parse HEAD)
        sha7=$(git rev-parse --short=7 HEAD)
        remote=$(git ls-remote origin "refs/heads/$branch") || die "can't read origin; check the network and try again"
        pushed=$(printf '%s\n' "$remote" | cut -f1)
        [ "$pushed" = "$head" ] || die "$sha7 is not pushed (origin/$branch is at ${pushed:-nothing}); push it first"
        items=$(parse "$file")
        handsoff=$(printf '%s\n' "$items" | awk -F'\t' '$3 == "hands-off"' | wc -l | tr -d ' ')
        jake=$(printf '%s\n' "$items" | awk -F'\t' '$3 == "jake"' | wc -l | tr -d ' ')
        pr=$(gh pr list --head "$branch" --json number --jq '.[0].number // empty')
        pr=${pr:+PR #$pr}
        {
            echo "Live checks request: $branch @ $sha7"
            echo
            echo "${pr:-No PR yet}: $handsoff hands-off, $jake for Jake."
            echo
            echo '```live-items'
            block "$file"
            echo '```'
        } | gh issue comment "$issue" --body-file -
        ;;
    *)
        echo "usage: live-request.sh post <issue> <items file> | items <file | ->" >&2
        exit 64
        ;;
esac
