#!/bin/sh
# ticket: the status lines a builder or Reviewer posts, by script, so they are
# posted once, in one format, and never wait on CI.
#
#   scripts/ticket.sh claim <issue>
#       Comments "Building: taking this (Claude)", adds building, removes
#       ready-for-agent. Refuses an issue without ready-for-agent, one already
#       claimed, one with a blocker that is not done (scripts/unblocked.sh), and
#       one that names .claude/settings.json (or the guard hook it wires) with no
#       "Decision (Jake ...)" yes for it: auto mode can't write that file, so the
#       ask goes to Jake before anyone builds.
#   scripts/ticket.sh ready <issue>
#       Comments "Ready for review: PR #M at <sha7>, CI pending" once and removes
#       building. Refuses a dirty tree, a HEAD that isn't the PR's head on GitHub,
#       and a check stamp (.build/check-stamp, written by scripts/check.sh) that
#       failed or is for other content. A stamp still counts after merges of
#       origin/main on top of the checked commit; CI checks the merge result.
#   scripts/ticket.sh ac <issue> [<n>=met:<url> | <n>=waived:<url> | <n>=moved:#N]... [--check]
#       Marks acceptance item n (numbered in order under "## Acceptance
#       criteria") met with an evidence link, waived with a Decision link, or
#       moved to another issue, and ticks its box. Refuses to write while any item
#       is unmarked, naming each by number. --check only reports.
#   scripts/ticket.sh later <pr> "<note>" --owner <issue> | --new
#       Turns a review note into an issue labelled later, owned by an open
#       ticket (which gets a comment pointing at it) or new for triage.
set -eu
cd "$(dirname "$0")/.."

die() { echo "ticket: $*" >&2; exit 1; }
usage() { sed -n 's/^#   \(scripts\/ticket.sh .*\)/\1/p' "$0" >&2; exit 64; }

first_lines() { jq -r '.comments[] | .body | (split("\n")[0] // "")'; }

claim() {
    n=$1
    issue=$(gh issue view "$n" --json number,title,state,labels,body,comments)
    labels=$(printf '%s' "$issue" | jq -r '[.labels[].name] | join(" ")')
    [ "$(printf '%s' "$issue" | jq -r .state)" = OPEN ] || die "#$n is closed"
    case " $labels " in *" building "*) die "#$n is already claimed (it has building)" ;; esac
    held=$(printf '%s' "$issue" | first_lines | grep '^Building:' | tail -n 1 || true)
    [ -z "$held" ] || die "#$n is already claimed: \"$held\""
    case " $labels " in *" ready-for-agent "*) ;; *) die "#$n has no ready-for-agent label" ;; esac

    # The scope line names what the ticket changes when there is one; otherwise
    # the body does, without its collapsed change details.
    scope=$(printf '%s' "$issue" | jq -r '.body | gsub("\r"; "") | split("\n")
        | (map(select(test("^\\**Files this ticket owns"))) | first) // (
            reduce .[] as $l ({in: false, out: []};
                if ($l | test("^<details>")) then .in = true
                elif ($l | test("^</details>")) then .in = false
                elif .in then . else .out += [$l] end) | .out | join("\n"))')
    if printf '%s' "$scope" | grep -q -E 'settings\.json|\.claude/hooks/|guard hook'; then
        yes=$(printf '%s' "$issue" | jq -r '[.body, .comments[].body] | .[] | split("\n")[]
            | select(test("^\\**Decision \\(Jake")) | select(test("settings\\.json"))' | head -n 1)
        [ -n "$yes" ] || die "#$n changes .claude/settings.json (or the guard hook it wires), which auto mode can't write, and has no \"Decision (Jake, <date>): ...settings.json...\" yes. Post \"Jake: decide ...\" on #$n with waiting-on-jake instead of building."
    fi
    waits=$(scripts/unblocked.sh --check "$n" 2>&1) || die "not claimed: ${waits#unblocked: }"

    gh issue comment "$n" --body "Building: taking this (Claude)" > /dev/null
    gh issue edit "$n" --add-label building --remove-label ready-for-agent > /dev/null
    echo "ticket: claimed #$n ($(printf '%s' "$issue" | jq -r .title))"
}

# Succeeds when the check stamp vouches for commit $1: its content, or that
# commit itself for a stamp written without a tree.
stamped() {
    if [ -n "$stamp_tree" ]; then
        [ "$(git rev-parse "$1^{tree}")" = "$stamp_tree" ]
    else
        [ "$(git rev-parse "$1")" = "$stamp_sha" ]
    fi
}

ready() {
    n=$1
    [ -z "$(git status --porcelain)" ] || die "the tree is dirty; commit or drop the changes first"
    branch=$(git branch --show-current)
    pr=$(gh pr view --json number,headRefOid,state 2> /dev/null) || die "no open PR for $branch"
    m=$(printf '%s' "$pr" | jq -r .number)
    head=$(git rev-parse HEAD)
    [ "$(printf '%s' "$pr" | jq -r .headRefOid)" = "$head" ] ||
        die "HEAD $(git rev-parse --short HEAD) isn't PR #$m's head on GitHub ($(printf '%s' "$pr" | jq -r '.headRefOid[:7]')); push first"

    stamp=.build/check-stamp
    [ -f "$stamp" ] || die "no check stamp ($stamp); run scripts/check.sh"
    stamp_sha=$(sed -n 's/^sha=//p' "$stamp")
    stamp_tree=$(sed -n 's/^tree=//p' "$stamp")
    stamp_exit=$(sed -n 's/^exit=//p' "$stamp")
    [ "$stamp_exit" = 0 ] || die "the last check failed (check exit $stamp_exit); fix it and run scripts/check.sh"
    c=$head
    until stamped "$c"; do
        if git rev-parse -q --verify "$c^2" > /dev/null && git merge-base --is-ancestor "$c^2" origin/main; then
            c=$(git rev-parse "$c^1")
        else
            die "the check stamp is for $(printf '%.7s' "$stamp_sha"), not this content at $(git rev-parse --short HEAD); run scripts/check.sh"
        fi
    done

    sha7=$(git rev-parse --short=7 HEAD)
    line="Ready for review: PR #$m at $sha7, CI pending"
    if gh issue view "$n" --json comments | first_lines | grep -q -F "Ready for review: PR #$m at $sha7"; then
        echo "ticket: #$n already has \"Ready for review: PR #$m at $sha7\""
    else
        gh issue comment "$n" --body "$line" > /dev/null
        echo "ticket: posted on #$n: $line"
    fi
    gh issue edit "$n" --remove-label building > /dev/null
}

ac() {
    n=$1
    shift
    check=
    marks=
    for arg in "$@"; do
        case "$arg" in
            --check) check=1 ;;
            [0-9]*=met:https://* | [0-9]*=waived:https://* | [0-9]*=moved:#[0-9]*) marks="$marks $arg" ;;
            *) die "bad mark '$arg': use <n>=met:<url>, <n>=waived:<decision url> or <n>=moved:#N" ;;
        esac
    done
    body=$(gh issue view "$n" --json body | jq -r .body | tr -d '\r')
    # Prints the new body, a line "@@problems", then one "unmarked <n> <text>" or
    # "unknown <n>" line per problem.
    result=$(printf '%s\n' "$body" | awk -v marks="$marks" '
        BEGIN { k = split(marks, m, " "); for (i = 1; i <= k; i++) if (m[i] != "") {
            split(m[i], p, "="); want[p[1]] = substr(m[i], index(m[i], "=") + 1); sub(/:/, ": ", want[p[1]]) } }
        /^## / { inAc = tolower($0) ~ /^## acceptance criteria/ }
        inAc && /^- \[[ xX]\] / {
            n++
            if (n in want) { sub(/ *\((met|waived|moved): [^)]*\)$/, ""); $0 = $0 " (" want[n] ")"; delete want[n] }
            if ($0 ~ /\((met|waived|moved): [^)]+\)$/) sub(/^- \[[ ]\]/, "- [x]")
            else { t = $0; sub(/^- \[[ xX]\] */, "", t); bad = bad "unmarked " n " " substr(t, 1, 80) "\n" }
        }
        { print }
        END { for (i in want) bad = bad "unknown " i "\n"; printf "@@problems\n%s", bad }')
    problems=$(printf '%s\n' "$result" | sed '1,/^@@problems$/d')
    if [ -n "$problems" ]; then
        printf '%s\n' "$problems" | while read -r kind i text; do
            [ -n "$kind" ] || continue
            if [ "$kind" = unknown ]; then echo "ticket: #$n has no acceptance item $i"
            else echo "ticket: #$n item $i is unmarked: $text"; fi
        done >&2
        die "not written: mark every item met, waived or moved"
    fi
    [ -z "$check" ] || { echo "ticket: every acceptance item on #$n is marked"; return 0; }
    printf '%s\n' "$result" | sed '/^@@problems$/,$d' | gh issue edit "$n" --body-file - > /dev/null
    echo "ticket: marked #$n's acceptance items"
}

later() {
    pr=$1
    note=$2
    shift 2
    case "${1:-}" in
        --owner) owner=$(printf %s "${2:?usage}" | tr -d '#'); labels=later; who="Owner: #$owner" ;;
        --new) owner=; labels=later,needs-triage; who="Owner: none yet, a new ticket for triage" ;;
        *) usage ;;
    esac
    title=$(printf '%s' "$note" | head -n 1 | cut -c 1-70)
    url=$(printf '%s\n\nFrom the review of PR #%s.\n%s\n' "$note" "$pr" "$who" |
        gh issue create --title "Later: $title" --label "$labels" --body-file -)
    if [ -n "$owner" ]; then
        gh issue comment "$owner" --body "Later from PR #$pr: #${url##*/} is yours ($title)." > /dev/null
    fi
    echo "ticket: $url"
}

case "${1:-}" in
    claim) [ $# -eq 2 ] || usage; claim "$2" ;;
    ready) [ $# -eq 2 ] || usage; ready "$2" ;;
    ac) [ $# -ge 2 ] || usage; shift; ac "$@" ;;
    later) [ $# -ge 4 ] || usage; shift; later "$@" ;;
    *) usage ;;
esac
