#!/bin/sh
# unblocked: the frontier, by the one rule for blockers: a blocker is done when
# its PR has merged (or the issue is closed). GitHub's own blocked-by counts any
# open issue, and tickets Jake can feel stay open after their PR merges.
#
#   scripts/unblocked.sh            each open ready-for-agent issue whose blockers
#                                   are done, with a one-line builder chip, then
#                                   the ones still waiting and on what
#   scripts/unblocked.sh --check N  exits 0 when every blocker of #N is done, else
#                                   names the ones that are not (ticket.sh claim)
#
# Blockers are the #N in the issue's "## Blocked by" section, unless it starts
# with "none". A blocker's PR is one whose branch is claude/issue-N or whose body
# starts "Refs #N". The chip copies the ticket's "Needs the Live checks session
# for:" line as written.
set -eu
cd "$(dirname "$0")/.."

check=
case "${1:-}" in
    --check) check=${2:?usage: unblocked.sh [--check N]} ;;
    "") ;;
    *) echo "usage: unblocked.sh [--check N]" >&2; exit 64 ;;
esac

tmp=$(mktemp -d -t unblocked)
trap 'rm -rf "$tmp"' EXIT
gh issue list --state all --limit 1000 --json number,title,state,labels,body > "$tmp/issues.json"
gh pr list --state merged --limit 1000 --json number,headRefName,body > "$tmp/prs.json"

# One object per issue: number, state, title, labels, needs line, and each
# blocker with whether it is done and why.
jq -n --slurpfile issues "$tmp/issues.json" --slurpfile prs "$tmp/prs.json" '
    def lines: (. // "") | gsub("\r"; "") | split("\n");
    def section($l): ([range(0; $l | length) | select($l[.] | test("^## Blocked by"; "i"))] | first) as $i
        | if $i == null then [] else
            $l[$i + 1:] | ((map(test("^## |^<details>")) | index(true)) as $end | if $end then .[:$end] else . end)
          end;
    def blockers: lines as $l | section($l) | map(select(test("\\S"))) as $s
        | if ($s | length) == 0 or ($s[0] | test("^\\s*(- )?none"; "i")) then []
          else [$s[] | scan("#([0-9]+)") | .[0] | tonumber] | unique end;
    def needs: [lines[] | select(test("Needs the Live checks session for:"))] | first
        | if . == null then null else sub(".*session for:\\**\\s*"; "") end;
    ($issues[0] | map({key: (.number | tostring), value: .}) | from_entries) as $byNum
    | ($prs[0] | map(. as $p | ([$p.headRefName | capture("^claude/issue-(?<n>[0-9]+)$") | .n]
        + [(($p.body // "") | lines | first // "") | capture("^Refs #(?<n>[0-9]+)\\b") | .n])
        | unique[] | {key: ., value: $p.number}) | from_entries) as $prFor
    | $issues[0][]
    | {number, state, title, labels: [.labels[].name], needs: (.body | needs),
       blockers: [.body | blockers[] | tostring as $b
         | {number: ., issue: $byNum[$b], pr: $prFor[$b]}
         | .done = ((.issue.state // "") == "CLOSED" or .pr != null)
         | .why = (if .pr != null then "PR #\(.pr) merged" elif .done then "closed"
                   elif .issue == null then "not found" else "open, no merged PR" end)
         | {number, done, why}]}
' > "$tmp/all.json"

if [ -n "$check" ]; then
    jq -e --argjson n "$check" 'select(.number == $n)' "$tmp/all.json" > /dev/null ||
        { echo "unblocked: no issue #$check" >&2; exit 1; }
    waiting=$(jq -r --argjson n "$check" 'select(.number == $n)
        | [.blockers[] | select(.done | not) | "#\(.number) (\(.why))"] | join(", ")' "$tmp/all.json")
    if [ -n "$waiting" ]; then
        echo "unblocked: #$check waits on $waiting" >&2
        exit 1
    fi
    exit 0
fi

jq -r 'select(.state == "OPEN") | select(.labels | index("ready-for-agent")) | select(.labels | (index("building") or index("waiting-on-jake") or index("parked")) | not)
    | select(all(.blockers[]; .done))
    | "#\(.number) \(.title)\(if (.blockers | length) > 0 then " (" + ([.blockers[] | "#\(.number): \(.why)"] | join(", ")) + ")" else "" end)\n  chip: You are a Lexicon builder (repo ~/code/lexicon). Build issue #\(.number) \"\(.title)\" with the implement-ticket skill. Needs the Live checks session for: \(.needs // "(no Needs line; run scripts/ticket-lint.sh \(.number))" | sub("[.\\s]+$"; "")). Refs #\(.number)."' \
    "$tmp/all.json" > "$tmp/frontier"
jq -r 'select(.state == "OPEN") | select(.labels | index("ready-for-agent")) | select(any(.blockers[]; .done | not))
    | "#\(.number) \(.title): waits on \([.blockers[] | select(.done | not) | "#\(.number) (\(.why))"] | join(", "))"' \
    "$tmp/all.json" > "$tmp/waiting"

if [ -s "$tmp/frontier" ]; then
    echo "Unblocked (a blocker is done when its PR has merged):"
    cat "$tmp/frontier"
else
    echo "Unblocked: none"
fi
if [ -s "$tmp/waiting" ]; then
    echo "Still blocked:"
    sed 's/^/  /' "$tmp/waiting"
fi
