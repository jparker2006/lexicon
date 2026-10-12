#!/bin/sh
# ticket-lint: checks a ticket's shape before it gets ready-for-agent, so each
# acceptance item can run when the ticket is built: what it needs on main, who
# runs it, and how long Jake's part takes.
#
#   scripts/ticket-lint.sh <issue> [--fix]   lint the issue's body on GitHub
#   scripts/ticket-lint.sh --file <path>     lint a body in a file
#
# The rules:
#   - Acceptance items sit under "### Headless", "### Live" or "### Jake" inside
#     "## Acceptance criteria". Items are numbered in order across all three.
#   - A Live or Jake item carries "needs: #N" (or "needs: none"), and every #N an
#     item needs is in "## Blocked by". --fix adds the missing ones there.
#   - A Jake item carries "Jake time: N items x S s = M min", N counted from data.
#   - "Needs the Live checks session for:" is "none", or "agent: <what> | Jake:
#     <what> (M min)", with an agent part when there are Live items and a Jake part
#     whose minutes add up the Jake items.
#   - "## Open questions" is there and empty.
#   - A ticket whose Modules line (or body, without one) names 3 or more modules
#     under Sources/ has a "Sketch:" link from /pstack:architect.
# The lint checks shape, not truth: whether an item can really run is a reader's call.
set -eu
cd "$(dirname "$0")/.."

usage() { echo "usage: ticket-lint.sh <issue> [--fix] | --file <path>" >&2; exit 64; }

fix=
case "${1:-}" in
    --file) [ -n "${2:-}" ] || usage; name=$2; body=$(cat "$2") ;;
    [0-9]*)
        name="#$1"
        issue=$1
        [ "${2:-}" = --fix ] && fix=1
        body=$(gh issue view "$1" --json body | jq -r .body)
        ;;
    *) usage ;;
esac
modules=$(ls Sources | tr '\n' ' ')

# Prints one problem per line; with mode=fix, prints the body with the needed
# Blocked by edges added instead.
lint() {
    printf '%s\n' "$body" | tr -d '\r' | awk -v modules="$modules" -v mode="$1" '
    function trim(s) { gsub(/^[ \t*]+|[ \t*.]+$/, "", s); return s }
    function refs(s, out,   n, t) {
        n = 0
        while (match(s, /#[0-9]+/)) { out[++n] = substr(s, RSTART + 1, RLENGTH - 1); s = substr(s, RSTART + RLENGTH) }
        return n
    }
    { lines[NR] = $0 }
    /^<details>/ { details = 1 }
    /^<\/details>/ { details = 0; next }
    details { next }
    /^## / {
        sec = tolower($0); sub_ = ""
        if (sec ~ /^## blocked by/) { blockedLine = NR; blockedSeen = 1 }
        if (sec ~ /^## open questions/) openSeen = 1
        next
    }
    /^### / { sub_ = tolower(trim(substr($0, 5))); next }
    sec ~ /^## acceptance criteria/ {
        if ($0 ~ /^- \[[ xX]\]/) { n++; type[n] = sub_; text[n] = $0; next }
        if (n > 0 && $0 !~ /^[ \t]*$/) text[n] = text[n] "\n" $0
        next
    }
    sec ~ /^## blocked by/ {
        if ($0 ~ /^[ \t]*$/) next
        blockedEnd = NR
        if (!blockedFirst) { blockedFirst = 1; if (tolower(trim($0)) ~ /^(- )?none/) blockedNone = 1 }
        if (!blockedNone) { k = refs($0, r); for (i = 1; i <= k; i++) blocked[r[i]] = 1 }
        next
    }
    sec ~ /^## open questions/ { if ($0 !~ /^[ \t]*$/) openText = 1 }
    /Needs the Live checks session for:/ { needsLine = trim(substr($0, index($0, "for:") + 4)); needsSeen = 1 }
    /^(\*\*)?Modules:/ { modulesLine = $0 }
    /Sketch:/ && /(https?:|\]\()/ { sketch = 1 }
    { all = all "\n" $0 }
    END {
        if (n == 0) problem("no acceptance items under ## Acceptance criteria")
        jakeMin = 0
        for (i = 1; i <= n; i++) {
            t = type[i]
            if (t != "headless" && t != "live" && t != "jake") {
                problem("item " i " is not under a ### Headless, ### Live or ### Jake heading"); continue
            }
            if (t == "live") hasLive = 1
            if (t == "jake") hasJake = 1
            if (match(text[i], /needs:[ ]*(none|#[0-9]+([ ,and]+#[0-9]+)*)/)) {
                k = refs(substr(text[i], RSTART, RLENGTH), r)
                for (j = 1; j <= k; j++) {
                    need[r[j]] = 1
                    if (!(r[j] in blocked)) problem("item " i " needs #" r[j] ", which is not in ## Blocked by")
                }
            } else if (t != "headless") {
                problem("item " i " (" (t == "live" ? "Live" : "Jake") ") has no needs: #N (or needs: none)")
            }
            if (t == "jake") {
                if (match(text[i], /Jake time: [0-9]+ items? x [0-9]+ s = [0-9]+ min/)) {
                    split(substr(text[i], RSTART, RLENGTH), f, /[ :]+/)
                    m = int((f[3] * f[6] + 59) / 60)
                    if (f[9] != m) problem("item " i ": Jake time " f[3] " x " f[6] " s is " m " min, not " f[9])
                    jakeMin += f[9]
                } else {
                    problem("item " i " (Jake) has no \"Jake time: N items x S s = M min\" line")
                }
            }
        }
        if (!needsSeen) problem("no \"Needs the Live checks session for:\" line")
        else if (!hasLive && !hasJake) {
            if (tolower(needsLine) != "none") problem("the Needs line should be \"none\": no Live or Jake items")
        } else {
            if (tolower(needsLine) == "none") problem("the Needs line says none, but there are " (hasLive ? "Live" : "Jake") " items")
            if (hasLive && needsLine !~ /agent:/) problem("the Needs line has no \"agent:\" part for the Live items")
            if (hasJake && needsLine !~ /Jake:/) problem("the Needs line has no \"Jake:\" part for the Jake items")
            if (hasJake && needsLine !~ ("\\(" jakeMin " min\\)")) problem("the Needs line should give Jake " jakeMin " min, the sum of the Jake items")
        }
        if (!openSeen) problem("no ## Open questions heading")
        else if (openText) problem("## Open questions is not empty")
        scope = modulesLine != "" ? modulesLine : all
        split(modules, mods, " "); named = ""; count = 0
        for (i in mods) if (mods[i] != "" && scope ~ ("(^|[^A-Za-z])" mods[i] "([^A-Za-z]|$)")) { count++; named = named (named == "" ? "" : ", ") mods[i] }
        if (count >= 3 && !sketch) problem("names " count " modules (" named ") and has no Sketch: link from /pstack:architect")
        if (mode == "fix") fixed()
    }
    function problem(s) { if (mode != "fix") print s }
    # The body with every needed #N in Blocked by, in place of "none" if it said so.
    function fixed(   i, add, out) {
        add = ""
        for (k in need) if (!(k in blocked)) add = add "- #" k "\n"
        for (i = 1; i <= NR; i++) {
            if (blockedNone && i > blockedLine && i <= blockedEnd) continue
            print lines[i]
            if (i == blockedLine && add != "") printf "%s", (blockedNone ? "\n" : "")
            if (i == (blockedEnd ? blockedEnd : blockedLine) && add != "") printf "%s%s", (blockedEnd && !blockedNone ? "" : "\n"), add
        }
        if (!blockedSeen && add != "") printf "\n## Blocked by\n\n%s", add
    }'
}

if [ -n "$fix" ]; then
    lint fix | gh issue edit "$issue" --body-file - > /dev/null
    body=$(gh issue view "$issue" --json body | jq -r .body)
fi
problems=$(lint check)
if [ -n "$problems" ]; then
    printf '%s\n' "$problems" | while IFS= read -r line; do echo "ticket-lint: $name: $line"; done >&2
    exit 1
fi
echo "ticket-lint: $name passes"
