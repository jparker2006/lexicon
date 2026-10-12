#!/bin/sh
# watch-events: the one watcher. Polls GitHub and prints one line per new event,
# for the role watching, so nobody hand-writes a polling loop. Run it in the
# background (or under Monitor) and act on each line. It only reads: it never
# comments, labels or merges.
#
#   scripts/watch-events.sh --role reviewer|livechecks|orchestrator|builder
#                           [--issue N] [--interval S] [--once]
#
#   READY         a comment starting "Ready for review"
#   FIXED-REVIEW  a comment starting "Fixed review"
#   VERDICT       a comment starting "Verdict" or "**Reviewer verdict"
#   LIVE-REQUEST  a comment starting "Live checks request:"
#   LIVE-RESULT   a comment starting "Live checks:"
#   JAKE-ASK      a comment starting "Jake:"
#   MERGED        an open PR that merged; CLOSED, one closed unmerged
#   HEAD-MOVED    an open PR's head changed (a push or a main merge)
#   CI            a CI run that completed, with its conclusion, on main or a PR
#
# Comments are read on open issues and open PRs: a builder's lines go on its
# issue, the Reviewer's on the PR. Each event fires once: comments are keyed by
# id, runs by id and attempt (a re-run fires again), heads by PR and sha. PRs
# are compared as sets between polls, never by number, so a lower-numbered PR
# merging late is still seen. The first poll only records what is already
# there; status.sh shows the current state.
#
# Roles: the reviewer gets READY, FIXED-REVIEW, CI, MERGED, CLOSED, HEAD-MOVED
# and LIVE-RESULT; livechecks gets LIVE-REQUEST, HEAD-MOVED and MERGED; a
# builder (with --issue N) gets every event on its issue and its PRs; the
# orchestrator gets everything. State and the running watcher's pid live in
# ~/Library/Application Support/Lexicon Dev/watch/, where status.sh looks.
set -eu
cd "$(dirname "$0")/.."

usage() { echo "usage: watch-events.sh --role reviewer|livechecks|orchestrator|builder [--issue N] [--interval S] [--once]" >&2; exit 64; }
role=
issue=
interval=60
once=
while [ $# -gt 0 ]; do
    case "$1" in
        --role) role=${2:-}; shift ;;
        --issue) issue=${2:-}; shift ;;
        --interval) interval=${2:-}; shift ;;
        --once) once=1 ;;
        *) usage ;;
    esac
    shift
done
case "$role" in
    reviewer) types="READY FIXED-REVIEW CI MERGED CLOSED HEAD-MOVED LIVE-RESULT" ;;
    livechecks) types="LIVE-REQUEST HEAD-MOVED MERGED" ;;
    orchestrator | builder) types=all ;;
    *) usage ;;
esac
[ "$role" != builder ] || [ -n "$issue" ] || usage
case "$interval" in "" | *[!0-9]* | 0) usage ;; esac

dir="$HOME/Library/Application Support/Lexicon Dev/watch"
name=$role${issue:+-$issue}
state="$dir/$name.state"
mkdir -p "$dir"
tmp=$(mktemp -d -t watch-events)
cleanup() { rm -rf "$tmp"; [ -n "$once" ] || rm -f "$dir/$name.pid"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# Every step returns on failure: the loop calls poll where set -e is off, and a
# poll that half-ran must leave the state as it was, or its events are lost.
poll() {
    gh issue list --state open --limit 500 --json number,comments > "$tmp/issues.json" || return 1
    gh pr list --state open --limit 100 --json number,headRefName,headRefOid,body,comments > "$tmp/prs.json" || return 1
    gh run list --limit 100 --json databaseId,attempt,headSha,headBranch,status,conclusion,updatedAt > "$tmp/runs.json" || return 1
    [ -f "$state" ] || echo null > "$state"
    # PRs that were open last time and aren't now: merged or closed.
    jq -r --slurpfile prs "$tmp/prs.json" '(.heads // {}) | keys[] as $n
        | select([$prs[0][].number | tostring] | index($n) | not) | $n' "$state" > "$tmp/gone" || return 1
    : > "$tmp/gone.jsonl"
    while read -r n; do
        gh pr view "$n" --json number,state,mergedAt,closedAt,mergeCommit,headRefName,body,comments >> "$tmp/gone.jsonl" || return 1
    done < "$tmp/gone"
    jq -s . "$tmp/gone.jsonl" > "$tmp/gone.json" || return 1

    jq -n -r --slurpfile prev "$state" --slurpfile issues "$tmp/issues.json" --slurpfile prs "$tmp/prs.json" \
        --slurpfile runs "$tmp/runs.json" --slurpfile gone "$tmp/gone.json" \
        --arg types "$types" --arg issue "$issue" --arg who "$name" '
        def kind: (split("\n")[0] // "") as $l
            | if ($l | test("^Ready for review")) then "READY"
              elif ($l | test("^Fixed review")) then "FIXED-REVIEW"
              elif ($l | test("^(Verdict|\\*\\*Reviewer verdict)")) then "VERDICT"
              elif ($l | test("^Live checks request:")) then "LIVE-REQUEST"
              elif ($l | test("^Live checks:")) then "LIVE-RESULT"
              elif ($l | test("^Jake:")) then "JAKE-ASK"
              else null end;
        def issue_of: ([(.headRefName // "") | capture("^claude/issue-(?<n>[0-9]+)$") | .n]
            + [((.body // "") | gsub("\r"; "") | (split("\n")[0] // "")) | capture("^Refs #(?<n>[0-9]+)\\b") | .n])[0];
        def short: .[0:7];
        def when: if . == null then "" else fromdateiso8601 | strflocaltime("%H:%M") end;
        $prev[0] as $p | ($p == null) as $first
        | (($p.comments // []) | map({key: ., value: true}) | from_entries) as $seenC
        | (($p.runs // []) | map({key: ., value: true}) | from_entries) as $seenR
        | ($p.heads // {}) as $heads
        | ($prs[0] | map({key: .headRefName, value: .number}) | from_entries) as $prOfBranch
        | ($prs[0] + $gone[0] | map({key: (.number | tostring), value: issue_of}) | from_entries) as $issueOfPr
        | ([$issues[0][] | .number as $n | .comments[] | {where: "#\($n)", issue: ($n | tostring), c: .}]
           + [$prs[0][], $gone[0][] | .number as $n | .comments[]? | {where: "PR #\($n)", issue: $issueOfPr[$n | tostring], c: .}]) as $all
        | [$all[] | select($seenC[.c.id] | not) | (.c.body | kind) as $k | select($k != null)
            | {at: .c.createdAt, type: $k, issue, text: "\($k) \(.where) \(.c.body | (split("\n")[0] // "") | .[0:140]) \(.c.url // "")"}]
          + [$prs[0][] | select($heads[.number | tostring] != null and $heads[.number | tostring] != .headRefOid)
            | {at: null, type: "HEAD-MOVED", issue: issue_of,
               text: "HEAD-MOVED PR #\(.number) \($heads[.number | tostring] | short) -> \(.headRefOid | short)"}]
          + [$gone[0][] | if .state == "MERGED"
              then {at: .mergedAt, type: "MERGED", issue: issue_of, text: "MERGED PR #\(.number) as \(.mergeCommit.oid // "" | short)"}
              else {at: .closedAt, type: "CLOSED", issue: issue_of, text: "CLOSED PR #\(.number) without merging"} end]
          + [$runs[0][] | select(.status == "completed") | "\(.databaseId).\(.attempt)" as $key | select($seenR[$key] | not)
            | (if .headBranch == "main" then null else $prOfBranch[.headBranch] end) as $pr
            | {at: .updatedAt, type: "CI", issue: (if $pr then $issueOfPr[$pr | tostring] else null end),
               text: "CI \(if .headBranch == "main" then "main" elif $pr then "PR #\($pr)" else .headBranch end) \(.headSha | short) \(.conclusion)\(if .attempt > 1 then " (attempt \(.attempt))" else "" end)"}]
        | map(select($types == "all" or (.type as $t | $types | split(" ") | any(. == $t))))
        | map(select($issue == "" or .issue == $issue))
        | {first: $first,
           events: (if $first then [] else sort_by(.at // "") end),
           state: {comments: [$all[].c.id], runs: [$runs[0][] | select(.status == "completed") | "\(.databaseId).\(.attempt)"],
                   heads: ($prs[0] | map({key: (.number | tostring), value: .headRefOid}) | from_entries)}}
        | (.state | tojson) as $s
        | "STATE \($s)", (.events[] | "\(.at | when)\(if .at then " " else "" end)\(.text)"),
          (if .first then "watch-events: watching as \($who) from here; scripts/status.sh shows what is already open" else empty end)
    ' > "$tmp/out" || return 1
    sed -n 's/^STATE //p' "$tmp/out" > "$state.new"
    [ -s "$state.new" ] || return 1
    # Printed before the state is saved: a kill in between repeats an event on
    # the next start rather than losing it.
    grep -v '^STATE ' "$tmp/out" || true
    mv "$state.new" "$state"
}

if [ -n "$once" ]; then
    poll
    exit 0
fi
# Two watchers for one role would print every event twice.
if [ -f "$dir/$name.pid" ] && kill -0 "$(cat "$dir/$name.pid")" 2> /dev/null; then
    once=1 # so cleanup leaves the running watcher's pid file
    echo "watch-events: a $name watcher already runs (pid $(cat "$dir/$name.pid"))" >&2
    exit 1
fi
echo $$ > "$dir/$name.pid"
while :; do
    poll || echo "watch-events: poll failed; trying again in $interval s" >&2
    # In the background, so TERM ends the wait at once.
    sleep "$interval" &
    wait $!
done
